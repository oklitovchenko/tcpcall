%%% @doc
%%% Handles a TCP connection.

%%% @author Aleksey Morarash <aleksey.morarash@gmail.com>
%%% @since 10 Nov 2014
%%% @copyright 2014, Aleksey Morarash <aleksey.morarash@gmail.com>

-module(tcpcall_server).

-behaviour(gen_server).

%% API exports
-export(
   [start/1,
    queue_reply/3
   ]).

%% gen_server callback exports
-export(
   [init/1, handle_call/3, handle_info/2, handle_cast/2,
    terminate/2, code_change/3]).

%% Used by timer:apply_interval/4
-export([vacuum/1]).

-include("tcpcall.hrl").
-include("tcpcall_proto.hrl").
-include("tcpcall_types.hrl").

%% --------------------------------------------------------------------
%% Data type definitions
%% --------------------------------------------------------------------

-export_type(
   [server_options/0,
    server_option/0
   ]).

-type server_options() :: [server_option()].

-type server_option() ::
        {socket, port()} |
        {acceptor, pid()} |
        {receiver, tcpcall:receiver()}.

-record(
   state,
   {socket :: port(),
    options :: server_options(),
    ready = false :: boolean(),
    acceptor_pid :: pid(),
    acceptor_mon :: reference(),
    receiver :: tcpcall:receiver(),
    registry :: registry()
   }).

-define(VACUUM_PERIOD, 60 * 1000). %% one minute

%% internal signals
-define(SIG_READY, ready).
-define(SIG_SELF_DESTRUCT, self_destruct).

%% ----------------------------------------------------------------------
%% Erlang interface definitions

%% message with request to a local receiver process (on the server side)
-define(ARRIVE_REQUEST(BridgeRef, RequestRef, Request),
        {tcpcall_req, BridgeRef, RequestRef, Request}).

%% sent when the receiver process prepare a reply
-define(QUEUE_REPLY(RequestRef, Reply),
        {queue_reply, RequestRef, Reply}).

%% sent when the receiver process is unable to process the request
-define(QUEUE_ERROR(RequestRef, Reason),
        {queue_error, RequestRef, Reason}).

%% --------------------------------------------------------------------
%% API functions
%% --------------------------------------------------------------------

%% @doc Start TCP connection process (server side).
%% The function is called from tcpcall_acceptor module.
%% The process is spawned unlinked.
-spec start(Options :: server_options()) -> ok.
start(Options) ->
    {ok, Pid} =
        gen_server:start(
          ?MODULE, Options, _GenServerOptions = []),
    {socket, Socket} = lists:keyfind(socket, 1, Options),
    case gen_tcp:controlling_process(Socket, Pid) of
        ok ->
            ok = gen_server:cast(Pid, ?SIG_READY);
        {error, closed} ->
            %% the server is going down
            ok
    end.

%% @doc Enqueue a reply for transferring to the remote side.
-spec queue_reply(BridgeRef :: tcpcall:bridge_ref(),
                  RequestRef :: reference(),
                  Reply :: tcpcall:data()) -> ok.
queue_reply(BridgeRef, RequestRef, Reply) ->
    ok = gen_server:cast(BridgeRef, ?QUEUE_REPLY(RequestRef, Reply)).

%% @hidden
%% @doc Enqueue an error reply for transferring to the remote side.
%% The function is not a part of module public API.
-spec queue_error(BridgeRef :: tcpcall:bridge_ref(),
                  RequestRef :: reference(),
                  Reason :: any()) -> ok.
queue_error(BridgeRef, RequestRef, Reason) ->
    EncodedReason = term_to_binary(Reason),
    ok = gen_server:cast(
           BridgeRef, ?QUEUE_ERROR(RequestRef, EncodedReason)).

%% --------------------------------------------------------------------
%% gen_server callback functions
%% --------------------------------------------------------------------

%% @hidden
-spec init(server_options()) ->
                  {ok, InitialState :: #state{}}.
init(Options) ->
    %% a mapping from RequestRef (of arrived request from
    %% the socket) to SeqNum for the reply which is going
    %% to send to the client side.
    %% The table is public to allow vacuuming from the
    %% another process.
    Registry = ets:new(?MODULE, [public]),
    %% If the 'self_destruct' signal will arrive before the 'ready'
    %% signal, the process will terminate.
    {ok, _TRef} = timer:send_after(1000, ?SIG_SELF_DESTRUCT),
    %% Monitor acceptor process. When it terminate, we will terminate too
    {acceptor, AcceptorPid} = lists:keyfind(acceptor, 1, Options),
    MonitorRef = monitor(process, AcceptorPid),
    {socket, Socket} = lists:keyfind(socket, 1, Options),
    {receiver, Receiver} = lists:keyfind(receiver, 1, Options),
    {ok,
     #state{socket = Socket,
            ready = false, %% will wait for 'ready' signal
            options = Options,
            acceptor_pid = AcceptorPid,
            acceptor_mon = MonitorRef,
            receiver = Receiver,
            registry = Registry}}.

%% @hidden
-spec handle_info(Request :: any(), State :: #state{}) ->
                         {noreply, State :: #state{}} |
                         {stop, Reason :: any(), NewState :: #state{}}.
handle_info({tcp, Socket, Data}, State)
  when Socket == State#state.socket, State#state.ready ->
    %% process data from the socket only when up and ready
    case handle_data_from_net(State, Data) of
        ok ->
            {noreply, State};
        stop ->
            {stop, _Reason = normal, State}
    end;
handle_info(?SIG_SELF_DESTRUCT, State) when not State#state.ready ->
    %% The 'self_destruct' signal arrived before the
    %% 'ready' signal. Something went wrong, cannot continue.
    {stop, _Reason = normal, State};
handle_info({tcp_closed, Socket}, State)
  when Socket == State#state.socket ->
    {stop, _Reason = normal, State};
handle_info({tcp_error, Socket, _Reason}, State)
  when Socket == State#state.socket ->
    {stop, _Reason = normal, State};
handle_info({'DOWN', MonitorRef, process, AcceptorPid, _Reason}, State)
  when MonitorRef == State#state.acceptor_mon,
       AcceptorPid == State#state.acceptor_pid ->
    %% connection acceptor process is down.
    {stop, _Reason = normal, State};
handle_info(_Request, State) ->
    {noreply, State}.

%% @hidden
-spec handle_cast(Request :: any(), State :: #state{}) ->
                         {noreply, NewState :: #state{}} |
                         {stop, Reason :: any(), NewState :: #state{}}.
handle_cast(?QUEUE_REPLY(RequestRef, Reply), State) ->
    %% Received a valid reply from the receiver process
    case pop_seq_num(State#state.registry, RequestRef) of
        {ok, SeqNum} ->
            case gen_tcp:send(
                   State#state.socket,
                   ?PACKET_REPLY(SeqNum, Reply)) of
                ok ->
                    {noreply, State};
                {error, _Reason} ->
                    {stop, _Reason = normal, State}
            end;
        undefined ->
            {noreply, State}
    end;
handle_cast(?QUEUE_ERROR(RequestRef, Reason), State) ->
    %% Received an error message from the receiver process
    case pop_seq_num(State#state.registry, RequestRef) of
        {ok, SeqNum} ->
            case gen_tcp:send(
                   State#state.socket,
                   ?PACKET_ERROR(SeqNum, Reason)) of
                ok ->
                    {noreply, State};
                {error, _Reason} ->
                    {stop, _Reason = normal, State}
            end;
        undefined ->
            {noreply, State}
    end;
handle_cast(?SIG_READY, State) ->
    %% The signal is sent by the acceptor process when it
    %% transfers socket ownership to the handler process.
    %% From the moment we can use the socket.
    ok = inet:setopts(State#state.socket, [{active, true}]),
    %% Schedule periodic vacuuming.
    {ok, _TRef} =
        timer:apply_interval(
          ?VACUUM_PERIOD,
          ?MODULE, vacuum, [State#state.registry]),
    {noreply, State#state{ready = true}};
handle_cast(_Request, State) ->
    {noreply, State}.

%% @hidden
-spec handle_call(Request :: any(), From :: any(), State :: #state{}) ->
                         {noreply, NewState :: #state{}}.
handle_call(_Request, _From, State) ->
    {noreply, State}.

%% @hidden
-spec terminate(Reason :: any(), State :: #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

%% @hidden
-spec code_change(OldVersion :: any(), State :: #state{}, Extra :: any()) ->
                         {ok, NewState :: #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ----------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------

%% @doc Handle a data packet from arrived from the network socket.
-spec handle_data_from_net(State :: #state{}, Data :: binary()) ->
                                  ok | stop.
handle_data_from_net(State, ?PACKET_REQUEST(SeqNum, DeadLine, Request)) ->
    RequestRef = make_ref(),
    ok = register_request_from_network(
           State#state.registry, SeqNum, RequestRef, DeadLine),
    %% relay the request to the receiver process
    case deliver_request(State#state.receiver, RequestRef, Request) of
        ok ->
            ok;
        error ->
            %% immediately reply to the remote side with error
            Reply = term_to_binary(no_proc),
            case gen_tcp:send(
                   State#state.socket,
                   ?PACKET_ERROR(SeqNum, Reply)) of
                ok ->
                    ok;
                {error, _Reason} ->
                    %% connection is broken. Terminate.
                    stop
            end
    end;
handle_data_from_net(_State, _BadOrUnknownPacket) ->
    %% ignore
    ok.

%% @doc Register request arrived from the network.
-spec register_request_from_network(
        Registry :: registry(),
        SeqNum :: seq_num(),
        RequestRef :: reference(),
        DeadLine :: pos_integer()) -> ok.
register_request_from_network(Registry, SeqNum, RequestRef, DeadLine) ->
    true = ets:insert(Registry, {RequestRef, SeqNum, DeadLine}),
    ok.

%% @doc Deliver request received from the remote side (the client)
%% to the local receiver process.
-spec deliver_request(Receiver :: tcpcall:receiver(),
                      RequestRef :: reference(),
                      Request :: tcpcall:data()) ->
                             ok | error.
deliver_request(ReceiverName, RequestRef, Request)
  when is_atom(ReceiverName) ->
    case whereis(ReceiverName) of
        Pid when is_pid(Pid) ->
            deliver_request(Pid, RequestRef, Request);
        undefined ->
            error
    end;
deliver_request(Pid, RequestRef, Request) when is_pid(Pid) ->
    ServerPid = self(),
    case is_process_alive(Pid) of
        true ->
            Msg = ?ARRIVE_REQUEST(ServerPid, RequestRef, Request),
            _Sent = Pid ! Msg,
            ok;
        false ->
            error
    end;
deliver_request(FunObject, RequestRef, Request)
  when is_function(FunObject, 1) ->
    ServerPid = self(),
    _Pid =
        spawn_link(
          fun() ->
                  try FunObject(Request) of
                      Reply when is_binary(Reply) ->
                          queue_reply(
                            ServerPid, RequestRef, Reply)
                  catch
                      ExcType:ExcReason ->
                          queue_error(
                            ServerPid, RequestRef,
                            {crashed,
                             [{type, ExcType},
                              {reason, ExcReason},
                              {stacktrace,
                               erlang:get_stacktrace()}]})
                  end
          end),
    ok.

%% @doc Lookup SeqNum by RequestRef and remove it from the
%% registry.
-spec pop_seq_num(Registry :: registry(),
                  RequestRef :: reference()) ->
                         {ok, SeqNum :: seq_num()} |
                         undefined.
pop_seq_num(Registry, RequestRef) ->
    case ets:lookup(Registry, RequestRef) of
        [{RequestRef, SeqNum, DeadLine}] ->
            true = ets:delete(Registry, RequestRef),
            Now = tcpcall_lib:micros(),
            if Now >= DeadLine ->
                    %% outdated reply. ignore it
                    undefined;
               true ->
                    {ok, SeqNum}
            end;
        [] ->
            undefined
    end.

%% @hidden
%% @doc Remove all expired items from the registry.
-spec vacuum(Registry :: registry()) -> ok.
vacuum(Registry) ->
    Now = tcpcall_lib:micros(),
    undefined =
        ets:foldl(
          fun({RequestRef, _SeqNum, DeadLine}, Accum)
             when Now >= DeadLine ->
                  true = ets:delete(Registry, RequestRef),
                  Accum;
             (_, Accum) ->
                  Accum
          end, undefined, Registry),
    ok.