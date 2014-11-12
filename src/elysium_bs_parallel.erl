%%%------------------------------------------------------------------------------
%%% @copyright (c) 2014, DuoMark International, Inc.
%%% @author Jay Nelson <jay@duomark.com> [http://duomark.com/]
%%% @reference 2014 Development sponsored by TigerText, Inc. [http://tigertext.com/]
%%% @reference The license is based on the template for Modified BSD from
%%%   <a href="http://opensource.org/licenses/BSD-3-Clause">OSI</a>
%%% @doc
%%%   Elysium_bs_parallel is a buffering strategy which enforces serial
%%%   initiation of Cassandra session queries, although the duration of
%%%   a query will vary so they are not guaranteed to execute in serial
%%%   order. This approach allows spikes in the traffic which exceed the
%%%   number of availabel elysium sessions. The buffer is maintained as
%%%   a FIFO ets_buffer, so it has overhead when unloading expired pending
%%%   requests when compared to a LIFO buffer for the same task. All
%%%   requests attempt to fetch an idle session before being added to
%%%   the end of the pending queue.
%%%
%%% @since 0.1.5
%%% @end
%%%------------------------------------------------------------------------------
-module(elysium_bs_parallel).
-author('jay@duomark.com').

%% External API
-export([
         insert_audit_counts/1,
         create_connection/3,
         checkin_connection/4,
         checkout_connection/1,
         handle_pending_request/6,
         pend_request/2,
         status/1
        ]).

%% FSM states
-type fun_request()   :: fun((pid(), [any()], seestar:consistency()) -> [any()]).
-type query_request() :: {bare_fun, config_type(), fun_request(), [any()], seestar:consistency()}
                       | {mod_fun, config_type(), module(), atom(), [any()], seestar:consistency()}.

-define(SERVER, ?MODULE).

-include("elysium_types.hrl").

-type timestamp() :: binary().
-record(audit_serial, {
          session_id_key    :: {module(), pid()},

          init_checkin      :: timestamp(),
          last_checkin      :: timestamp(),
          num_checkins  = 0 :: non_neg_integer(),

          init_checkout     :: timestamp(),
          last_checkout     :: timestamp(),
          num_checkouts = 0 :: non_neg_integer(),

          init_pending      :: timestamp(),
          last_pending      :: timestamp(),
          num_pendings  = 0 :: non_neg_integer()
         }).
-type audit_serial() :: #audit_serial{}.

-record(audit_serial_counts, {
          count_type_key            :: {module(), counts},
          pending_dead          = 0 :: non_neg_integer(),
          pending_ets_errors    = 0 :: non_neg_integer(),
          pending_missing_data  = 0 :: non_neg_integer(),
          pending_timeouts      = 0 :: non_neg_integer(),
          session_dead          = 0 :: non_neg_integer(),
          session_decay         = 0 :: non_neg_integer(),
          session_ets_errors    = 0 :: non_neg_integer(),
          session_missing_data  = 0 :: non_neg_integer(),
          session_timeouts      = 0 :: non_neg_integer(),
          session_wrong         = 0 :: non_neg_integer(),
          worker_errors         = 0 :: non_neg_integer(),
          worker_timeouts       = 0 :: non_neg_integer()
         }).
-type audit_serial_counts() :: #audit_serial_counts{}.

-export_type([audit_serial/0, audit_serial_counts/0]).

-define(COUNTS_KEY, {?MODULE, counts}).


%%%-----------------------------------------------------------------------
%%% External API
%%%-----------------------------------------------------------------------

-spec insert_audit_counts(atom()) -> true.
%% @doc Insert audit_serial_counts record to hold error increments.
insert_audit_counts(Audit_Name) ->
    Count_Rec = #audit_serial_counts{count_type_key=?COUNTS_KEY},
    true = ets:insert_new(Audit_Name, Count_Rec).

-type resource_counts() :: {idle_connections | pending_requests,
                            {atom(), non_neg_integer(), non_neg_integer()}}.
-spec status(config_type()) -> {status, [resource_counts()]}.
%% @doc Get the current queue size of the pending queue.
status(Config) ->
    {status, [idle_connections(Config),
              pending_requests(Config)]}.

-spec checkout_connection(config_type()) -> {{Ip::string(), Port::pos_integer()}, pid()} | none_available.
%% @doc
%%   Allocate a seestar_session to the caller by popping an entry
%%   from the front of the connection queue. This function either
%%   returns a live pid(), or none_available to indicate that all
%%   connections to Cassandra are currently checked out.
%%
%%   If there are internal delays on the ets_buffer FIFO queue,
%%   this function will retry. If the session handed back is no
%%   longer live, it is tossed and a new session is fetched. In
%%   both cases, up to Config_Module:checkout_max_retry attempts
%%   are tried before returning none_available. If the queue is
%%   actually empty, no retries are performed.
%%
%%   The configuration parameter is not validated because this
%%   function should be a hotspot and we don't want it to slow
%%   down or become a concurrency bottleneck.
%% @end
checkout_connection(Config) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Retries   = elysium_config:checkout_max_retry (Config),
    fetch_pid_from_queue(Config, Session_Queue, Max_Retries, -1).

-spec create_connection(config_type(), {Ip::string(), Port::pos_integer()}, Session_Id::pid())
                       -> {boolean() | pending, {session_queue_name(), Idle_Count, Max_Count}}
                              when Idle_Count :: max_sessions() | ets_buffer:buffer_error(),
                                   Max_Count  :: max_sessions() | ets_buffer:buffer_error().
%% @doc Create an audit ets_entry, then do checkin_connection.
create_connection(Config, {_Ip, _Port} = Node, Session_Id)
  when is_pid(Session_Id) ->
    Audit_Name = elysium_config:audit_ets_name(Config),
    Audit_Key  = {?MODULE, Session_Id},
    true = ets:insert_new(Audit_Name, #audit_serial{session_id_key=Audit_Key, init_checkin=timestamp()}),
    checkin_connection(Config, Node, Session_Id, true).
                               
-spec checkin_connection(config_type(), {Ip::string(), Port::pos_integer()},
                         Session_Id::pid(), Is_New_Connection::boolean())
                        -> {boolean() | pending, {session_queue_name(), Idle_Count, Max_Count}}
                               when Idle_Count :: max_sessions() | ets_buffer:buffer_error(),
                                    Max_Count  :: max_sessions() | ets_buffer:buffer_error().
%% @doc
%%   Checkin a seestar_session, IF there are no pending requests.
%%   A checkin will continue looping on the pending queue with
%%   the chance for decay on each attempt. If it decays, any
%%   newly spawned replacement is expected to check the pending
%%   queue for outstanding requests. Brand new connections are
%%   not checked for decay before first use.
%%
%%   This function can loop forever if there are pending requests,
%%   so it performs an asynchronous send_event.
%% @end
checkin_connection(Config, {_Ip, _Port} = Node, Session_Id, Is_New_Connection)
  when is_pid(Session_Id) ->
    Pending_Queue = elysium_config:requests_queue_name(Config),
    case is_process_alive(Session_Id) andalso ets_buffer:num_entries_dedicated(Pending_Queue) > 0 of
        false -> checkin_immediate (Config, Node, Session_Id, Pending_Queue, Is_New_Connection);
        true  -> checkin_pending   (Config, Node, Session_Id, Pending_Queue, Is_New_Connection)
    end.

-spec pend_request(config_type(), query_request()) -> any() | pend_request_error().
%%   Block the caller while the request is serially queued. When
%%   a session is avialable to run this pending request, the
%%   blocking recieve loop will unblock and a spawned process
%%   will execute the request, so that the caller can still
%%   timeout if the request takes too long.
%% @end
pend_request(Config, Query_Request) ->
    Sid_Reply_Ref = make_ref(),
    Start_Time    = os:timestamp(),
    Pending_Queue = elysium_config:requests_queue_name   (Config),
    Reply_Timeout = elysium_config:request_reply_timeout (Config),
    wait_for_session(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout).


%%%-----------------------------------------------------------------------
%%% Internal support functions
%%%-----------------------------------------------------------------------

idle_connections(Config) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Sessions  = elysium_config:session_max_count  (Config),
    Buffer_Count  = ets_buffer:num_entries_dedicated (Session_Queue),
    {idle_connections, report_available_resources(Session_Queue, Buffer_Count, Max_Sessions)}.
    
pending_requests(Config) ->
    Pending_Queue = elysium_config:requests_queue_name   (Config),
    Reply_Timeout = elysium_config:request_reply_timeout (Config),
    Pending_Count = ets_buffer:num_entries_dedicated (Pending_Queue),
    {pending_requests, report_available_resources(Pending_Queue, Pending_Count, Reply_Timeout)}.

report_available_resources(Queue_Name, {missing_ets_buffer, Queue_Name}, Max) ->
    {Queue_Name, {missing_ets_buffer, 0, Max}};
report_available_resources(Queue_Name, Num_Sessions, Max) ->
    {Queue_Name, Num_Sessions, Max}.

%% Internal loop function to retry getting from the queue.
fetch_pid_from_queue(_Config, _Session_Queue, Max_Retries, Times_Tried)
  when Times_Tried >= Max_Retries ->
    none_available;
fetch_pid_from_queue( Config,  Session_Queue, Max_Retries, Times_Tried) ->
    case ets_buffer:read_dedicated(Session_Queue) of

        %% Race condition with checkin, try again...
        %% (When this happens, a connection is left behind in the queue and will never get reused!)
        {missing_ets_data, Session_Queue, Read_Loc} ->
            _ = audit_count(Config, session_missing_data),
            lager:error("Missing ETS data reading ~p at location ~p~n", [Session_Queue, Read_Loc]),
            fetch_pid_from_queue(Config, Session_Queue, Max_Retries, Times_Tried+1);

        %% Give up if there are no connections available...
        [] -> none_available;

        %% Return only a live pid, otherwise get the next one.
        [{_Node, Session_Id} = Session_Data] when is_pid(Session_Id) ->
            case is_process_alive(Session_Id) of
                %% NOTE: we toss only MAX_CHECKOUT_RETRY dead pids
                false -> _ = audit_count(Config, session_dead),
                         fetch_pid_from_queue(Config, Session_Queue, Max_Retries, Times_Tried+1);
                true  -> _ = audit_data_checkout(Config, Session_Id),
                         Session_Data
            end;

        %% Somehow the connection buffer died, or something even worse!
        Error ->
            audit_count(Config, session_ets_errors),
            lager:error("Connection buffer error: ~9999p~n", [Error]),
            Error
    end.

wait_for_session(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout) ->
    Session_Queue = elysium_config:session_queue_name(Config),
    case fetch_pid_from_queue(Config, Session_Queue, 1, 0) of

        %% A free connection showed up since we first checked...
        {Node, Session_Id} when is_pid(Session_Id) ->
            case is_process_alive(Session_Id) of
                true  -> handle_pending_request(Config, 0, Reply_Timeout, Node, Session_Id, Query_Request);
                false -> _ = audit_count(Config, session_dead),
                         wait_for_session(Config, Pending_Queue, Sid_Reply_Ref,
                                          Start_Time, Query_Request, Reply_Timeout)
            end;

        %% None are still available, queue the request and wait for one to free up.
        _None_Available ->
            _Pending_Count = ets_buffer:write_dedicated(Pending_Queue, {{self(), Sid_Reply_Ref}, Start_Time}),
            wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout)
    end.

wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time, Query_Request, Reply_Timeout) ->
    receive
        %% A live elysium session channel is now available to make the request...
        {sid, Sid_Reply_Ref, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
            Elapsed_Time = timer:now_diff(os:timestamp(), Start_Time),
            case {Elapsed_Time >= Reply_Timeout * 1000, is_process_alive(Session_Id)} of

                %% Alas, we timed out waiting...
                {true,  true}  -> _ = audit_count(Config, session_timeouts),
                                  _ = checkin_connection(Config, Node, Session_Id, Is_New_Connection),
                                  {wait_for_session_timeout, Reply_Timeout};
                {true,  false} -> _ = audit_count(Config, session_dead),
                                  _ = audit_count(Config, session_timeouts),
                                  {wait_for_session_timeout, Reply_Timeout};

                %% Dead session, loop waiting for another (hopefully live) connection to free up...
                {false, false} -> _ = audit_count(Config, session_dead),
                                  New_Timeout = Reply_Timeout - (Elapsed_Time div 1000),
                                  wait_for_session(Config, Pending_Queue, Sid_Reply_Ref,
                                                   Start_Time, Query_Request, New_Timeout);

                %% Get some results while we still have time!
                {false, true}  -> handle_pending_request(Config, Elapsed_Time, Reply_Timeout,
                                                         Node, Session_Id, Query_Request)
            end;

        %% Previous timed out request sent a Session_Id late, check it in and wait for our expected one.
        {sid, _, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
            _ = audit_count(Config, session_wrong),
            _ = case is_process_alive(Session_Id) of
                    false -> audit_count(Config, session_dead);
                    true  -> checkin_immediate(Config, Node, Session_Id, Pending_Queue, Is_New_Connection)
                end,
            Elapsed_Time = timer:now_diff(os:timestamp(), Start_Time),
            case Elapsed_Time >= Reply_Timeout * 1000 of
                true -> _ = audit_count(Config, session_timeouts),
                        {wait_for_session_timeout, Reply_Timeout};
                false -> New_Timeout = Reply_Timeout - (Elapsed_Time div 1000),
                         wait_for_session_loop(Config, Pending_Queue, Sid_Reply_Ref, Start_Time,
                                               Query_Request, New_Timeout)
            end

        %% Any other messages are intended for the blocked caller, leave them in the message queue.

    after Reply_Timeout ->
            %% Handle race condition messaging vs timeout waiting for message.
            erlang:yield(),
            _ = receive
                    {sid, Sid_Reply_Ref, Node, Session_Id, Pending_Queue, Is_New_Connection} ->
                        case is_process_alive(Session_Id) of
                            false -> audit_count(Config, session_dead);
                            true  -> checkin_connection(Config, Node, Session_Id, Is_New_Connection)
                        end
                after 0 -> no_msgs
                end,
            _ = audit_count(Config, session_timeouts),
            {wait_for_session_timeout, Reply_Timeout}
    end.

%% Use the Session_Id to run the query if we aren't out of time
handle_pending_request(Config, Elapsed_Time, Reply_Timeout, Node, Session_Id, Query_Request) ->
    %% Self cannot be executed inside the fun(), it needs to be set in the current context.
    Self = self(),
    Worker_Reply_Ref = make_ref(),
    %% Avoiding export of exec_pending_request/5
    Worker_Fun = fun() -> exec_pending_request(Worker_Reply_Ref, Self, Node, Session_Id, Query_Request) end,
    {Worker_Pid, Worker_Monitor_Ref} = spawn_opt(Worker_Fun, [monitor]),   % May want to add other options
    Timeout_Remaining = Reply_Timeout - (Elapsed_Time div 1000),
    try   receive_worker_reply(Config, Worker_Reply_Ref, Timeout_Remaining, Worker_Pid, Worker_Monitor_Ref)
    after erlang:demonitor(Worker_Monitor_Ref, [flush])
    end.

%% Worker_Pid is passed to allow tracing
receive_worker_reply(Config, Worker_Reply_Ref, Timeout_Remaining, Worker_Pid, Worker_Monitor_Ref) ->
    receive
        {wrr, Worker_Reply_Ref, Reply} -> Reply;
        {'DOWN', Worker_Monitor_Ref, process, Worker_Pid, Reason} ->
            _ = audit_count(Config, worker_errors),
            {worker_reply_error, Reason}
    after Timeout_Remaining ->
            _ = audit_count(Config, worker_timeouts),
            {worker_reply_timeout, Timeout_Remaining}
    end.

-spec checkin_immediate(config_type(), {Ip::string(), Port::pos_integer()},
                        Session_Id::pid(), Pending_Queue::requests_queue_name(), Is_New_Connection::boolean())
                       -> {boolean(), {session_queue_name(), Idle_Count, Max_Count}}
                              when Idle_Count :: max_sessions() | ets_buffer:buffer_error(),
                                   Max_Count  :: max_sessions() | ets_buffer:buffer_error().
%% @doc
%%   Checkin a seestar_session by putting it at the end of the
%%   available connection queue. Returns whether the checkin was
%%   successful (it fails if the process is dead when checkin is
%%   attempted), and how many connections are available after the
%%   checkin.
%%
%%   Sessions have a fixed probability of failure on checkin.
%%   The decay probability is a number of chances of dying per
%%   1 Million checkin attempts. If the session is killed, it
%%   will be replaced by the supervisor automatically spawning
%%   a new worker and placing it at the end of the queue.
%%
%%   The configuration parameter is not validated because this
%%   function should be a hotspot and we don't want it to slow
%%   down or become a concurrency bottleneck.
%% @end
checkin_immediate(Config, Node, Session_Id, Pending_Queue, true) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Sessions  = elysium_config:session_max_count  (Config),
    case is_process_alive(Session_Id) of
        false -> _ = audit_count(Config, session_dead),
                 fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config);
        true  -> succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config, Pending_Queue, true)
    end;
checkin_immediate(Config, Node, Session_Id, Pending_Queue, false) ->
    Session_Queue = elysium_config:session_queue_name (Config),
    Max_Sessions  = elysium_config:session_max_count  (Config),
    case is_process_alive(Session_Id) of
        false -> _ = audit_count(Config, session_dead),
                 fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config);
        true  -> case decay_causes_death(Config, Session_Id) of
                     false -> succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id},
                                           Config, Pending_Queue, false);
                     true  -> _ = decay_session(Config, Session_Id),
                              fail_checkin(Session_Queue, Max_Sessions, {Node, Session_Id}, Config)
                  end
    end.

%% Session_Data is passed to allow tracing
fail_checkin(Session_Queue, Max_Sessions, {_Node, Session_Id}, Config) ->
    _ = audit_data_delete(Config, Session_Id),
    Available = ets_buffer:num_entries_dedicated(Session_Queue),
    {false, report_available_resources(Session_Queue, Available, Max_Sessions)}.

succ_checkin(Session_Queue, Max_Sessions, {Node, Session_Id} = Session_Data,
             Config, Pending_Queue, Is_New_Connection) ->
    case ets_buffer:num_entries_dedicated(Pending_Queue) > 0 of
        true  -> checkin_pending(Config, Node, Session_Id, Pending_Queue, Is_New_Connection);
        false -> Available  = checkin_session(Session_Queue, Session_Data),
                 _ = audit_data_checkin(Config, Session_Id),
                 {true, report_available_resources(Session_Queue, Available, Max_Sessions)}
    end.

checkin_session(Session_Queue, Session_Data) ->
    elysium_session_enqueuer:checkin_session(Session_Queue, Session_Data).

delay_checkin(Config) ->
    Session_Queue = elysium_config:session_queue_name  (Config),
    Max_Sessions  = elysium_config:session_max_count   (Config),
    Available     = ets_buffer:num_entries_dedicated (Session_Queue),
    {pending, report_available_resources(Session_Queue, Available, Max_Sessions)}.

decay_causes_death(Config, _Session_Id) ->
    case elysium_config:decay_probability(Config) of
        Never_Decays when is_integer(Never_Decays), Never_Decays =:= 0 ->
            false;
        Probability  when is_integer(Probability),  Probability   >  0, Probability =< 1000000000 ->
            R = elysium_random:random_int_up_to(1000000000),
            R =< Probability
    end.

decay_session(Config, Session_Id) ->
    Supervisor_Pid = elysium_queue:get_connection_supervisor(),
    _ = case elysium_connection_sup:stop_child(Supervisor_Pid, Session_Id) of
            {error, not_found} -> dont_replace_child;
            ok -> elysium_connection_sup:start_child(Supervisor_Pid, [Config])
        end,
    _ = audit_count(Config, session_decay),
    audit_data_delete(Config, Session_Id).

checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection) ->
    case ets_buffer:read_dedicated(Pending_Queue) of

        %% Race condition with pend_request, try again...
        %% (When this happens, a pending request is left behind in the queue and will timeout)
        {missing_ets_data, Pending_Queue, Read_Loc} ->
            _ = audit_count(Config, pending_missing_data),
            lager:error("Missing ETS data reading ~p at location ~p~n", [Pending_Queue, Read_Loc]),
            checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection);

        %% There are no pending requests, return the session...
        [] -> checkin_immediate(Config, Node, Sid, Pending_Queue, Is_New_Connection);

        %% Got a pending request, let's run it...
        [{{Waiting_Pid, Sid_Reply_Ref}, When_Originally_Queued}] ->

            Reply_Timeout = elysium_config:request_reply_timeout(Config),
            case timer:now_diff(os:timestamp(), When_Originally_Queued) of

                %% Too much time has passed, skip this request and try another...
                Expired when Expired > Reply_Timeout * 1000 ->
                    _ = audit_count(Config, pending_timeouts),
                    checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection);

                %% There's still time to reply, run the request if the session is still alive.
                _Remaining_Time ->
                    case is_process_alive(Waiting_Pid) of
                        false -> _ = audit_count(Config, pending_dead),
                                 checkin_pending(Config, Node, Sid, Pending_Queue, Is_New_Connection);
                        true  -> Waiting_Pid ! {sid, Sid_Reply_Ref, Node, Sid, Pending_Queue, Is_New_Connection},
                                 _ = audit_data_pending(Config, Sid),
                                 delay_checkin(Config)
                    end
            end;

        %% Somehow the pending buffer died, or something even worse!
        Error ->
            _ = audit_count(Config, pending_ets_errors),
            lager:error("Pending requests buffer error: ~9999p~n", [Error]),
            Error
    end.

%% Watch Out! This function swaps from the Config on a checkin request to the
%% Config on the original pending query. If you somehow mix connection queues
%% by passing different Configs, the clusters which queries run on may get
%% mixed up resulting in queries/updates/deletes talking to the wrong clusters.
exec_pending_request(Reply_Ref, Reply_Pid, Node, Sid, {bare_fun, Config, Query_Fun, Args, Consistency}) ->
    try   Reply = Query_Fun(Sid, Args, Consistency),
          Reply_Pid ! {wrr, Reply_Ref, Reply}
    catch A:B -> lager:error("Query execution caught ~p:~p for ~p ~p ~9999p~n",
                             [A,B, Reply_Pid, Args, erlang:get_stacktrace()])
    after _ = checkin_connection(Config, Node, Sid, false)
    end;
exec_pending_request(Reply_Ref, Reply_Pid, Node, Sid, {mod_fun,  Config, Mod,  Fun, Args, Consistency}) ->
    try   Reply = Mod:Fun(Sid, Args, Consistency),
          Reply_Pid ! {wrr, Reply_Ref, Reply}
    catch A:B -> lager:error("Query execution caught ~p:~p for ~p ~p ~9999p~n",
                             [A,B, Reply_Pid, Args, erlang:get_stacktrace()])
    after _ = checkin_connection(Config, Node, Sid, false)
    end.

%% Internal auditing functions
audit_count(Config, Type) ->
    Audit_Key   = {?MODULE, counts},
    Audit_Name  = elysium_config:audit_ets_name(Config),
    Counter_Pos = case Type of
                      pending_dead          -> #audit_serial_counts.pending_dead;
                      pending_ets_errors    -> #audit_serial_counts.pending_ets_errors;
                      pending_missing_data  -> #audit_serial_counts.pending_missing_data;
                      pending_timeouts      -> #audit_serial_counts.pending_timeouts;
                      session_dead          -> #audit_serial_counts.session_dead;
                      session_decay         -> #audit_serial_counts.session_decay;
                      session_ets_errors    -> #audit_serial_counts.session_ets_errors;
                      session_missing_data  -> #audit_serial_counts.session_missing_data;
                      session_timeouts      -> #audit_serial_counts.session_timeouts;
                      session_wrong         -> #audit_serial_counts.session_wrong;
                      worker_errors         -> #audit_serial_counts.worker_errors;
                      worker_timeouts       -> #audit_serial_counts.worker_timeouts
                  end,
    ets:update_counter(Audit_Name, Audit_Key, {Counter_Pos, 1}).


audit_data_checkin(Config, Session_Id) ->
    Audit_Name = elysium_config:audit_ets_name(Config),
    Audit_Key  = {?MODULE, Session_Id},
    case ets:lookup_element(Audit_Name, Audit_Key, #audit_serial.init_checkin) of
        undefined  -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.init_checkin, timestamp()});
        _Timestamp -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.last_checkin, timestamp()})
    end,
    ets:update_counter(Audit_Name, Audit_Key, {#audit_serial.num_checkins, 1}).

audit_data_pending(Config, Session_Id) ->
    Audit_Name = elysium_config:audit_ets_name(Config),
    Audit_Key  = {?MODULE, Session_Id},
    case ets:lookup_element(Audit_Name, Audit_Key, #audit_serial.init_pending) of
        undefined  -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.init_pending, timestamp()});
        _Timestamp -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.last_pending, timestamp()})
    end,
    ets:update_counter(Audit_Name, Audit_Key, {#audit_serial.num_pendings, 1}).

audit_data_checkout(Config, Session_Id) ->
    Audit_Name = elysium_config:audit_ets_name(Config),
    Audit_Key  = {?MODULE, Session_Id},
    case ets:lookup_element(Audit_Name, Audit_Key, #audit_serial.init_checkout) of
        undefined  -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.init_checkout, timestamp()});
        _Timestamp -> ets:update_element(Audit_Name, Audit_Key, {#audit_serial.last_checkout, timestamp()})
    end,
    ets:update_counter(Audit_Name, Audit_Key, {#audit_serial.num_checkouts, 1}).

audit_data_delete(Config, Session_Id) ->
    Audit_Name = elysium_config:audit_ets_name(Config),
    ets:delete(Audit_Name, {?MODULE, Session_Id}).

timestamp() ->
    TS = {_,_,Micro} = os:timestamp(),
    {{Year,Month,Day},{Hour,Minute,Second}} = calendar:now_to_universal_time(TS),
    Mstr = element(Month,{"Jan","Feb","Mar","Apr","May","Jun","Jul", "Aug","Sep","Oct","Nov","Dec"}),
    list_to_binary(io_lib:format("~4w-~s-~2wT~2w:~2..0w:~2..0w.~6..0w", [Year,Mstr,Day,Hour,Minute,Second,Micro])).
