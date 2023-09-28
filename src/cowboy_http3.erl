%% Copyright (c) 2023, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% A key difference between cowboy_http2 and cowboy_http3
%% is that HTTP/3 streams are QUIC streams and therefore
%% much of the connection state is handled outside of
%% Cowboy. The quicer library uses a reference for
%% identifying streams, and we use that same reference
%% for our StreamID internally. The real StreamID can
%% be retrieved via quicer:get_stream_id(StreamRef).

-module(cowboy_http3).

-export([init/3]).

%% Temporary callback to do sendfile over QUIC.
-export([send/2]).

-include_lib("quicer/include/quicer.hrl").

-record(stream, {
	%% @todo We shouldn't use the QUIC reference because it is a NIF object
	%%       and if it's stored somewhere by the user it'll never get GC.
	ref :: any(), %% @todo specs

	%% Whether the stream is currently in a special state.
	status :: header | normal | {data, non_neg_integer()} | discard,

	%% Stream buffer.
	buffer = <<>> :: binary(),

	%% Stream state.
	state :: {module, any()}
}).

-record(state, {
	parent :: pid(),
	conn :: any(), %% @todo specs
	opts = #{} :: any(), %% @todo opts(),

	%% Remote address and port for the connection.
	peer = undefined :: {inet:ip_address(), inet:port_number()},

	%% Local address and port for the connection.
	sock = undefined :: {inet:ip_address(), inet:port_number()},

	%% HTTP/3 state machine.
	http3_machine :: cow_http3_machine:http3_machine(),

	%% Bidirectional streams are used for requests and responses.
	streams = #{} :: map(), %% @todo specs

	%% Lingering streams that were recently reset. We may receive
	%% pending data or messages for these streams a short while
	%% after they have been reset.
	lingering_streams = [] :: [reference()],

	%% Streams can spawn zero or more children which are then managed
	%% by this module if operating as a supervisor.
	children = cowboy_children:init() :: cowboy_children:children()
}).

-spec init(_, _, _) -> no_return().
init(Parent, Conn, Opts) ->
	{ok, SettingsBin, HTTP3Machine0} = cow_http3_machine:init(server, Opts),
	%% Immediately open a control, encoder and decoder stream.
	{ok, ControlRef} = quicer:start_stream(Conn,
		#{open_flag => ?QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL}),
	{ok, _} = quicer:send(ControlRef, [<<0>>, SettingsBin]),
	{ok, EncoderRef} = quicer:start_stream(Conn,
		#{open_flag => ?QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL}),
	{ok, _} = quicer:send(EncoderRef, <<2>>),
	{ok, DecoderRef} = quicer:start_stream(Conn,
		#{open_flag => ?QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL}),
	{ok, _} = quicer:send(DecoderRef, <<3>>),
	%% Set the control, encoder and decoder streams in the machine.
	HTTP3Machine = cow_http3_machine:init_unidi_local_streams(
		ControlRef, EncoderRef, DecoderRef, HTTP3Machine0),
	%% Get the peername/sockname.
	Peer0 = quicer:peername(Conn),
	Sock0 = quicer:sockname(Conn),
	%% @todo Get the peer certificate here if it makes sense.
	case {Peer0, Sock0} of
		{{ok, Peer}, {ok, Sock}} ->
			%% Quick! Let's go!
			loop(#state{parent=Parent, conn=Conn, opts=Opts,
				peer=Peer, sock=Sock, http3_machine=HTTP3Machine});
		{{error, Reason}, _} ->
			terminate(undefined, {socket_error, Reason,
				'A socket error occurred when retrieving the peer name.'});
		{_, {error, Reason}} ->
			terminate(undefined, {socket_error, Reason,
				'A socket error occurred when retrieving the sock name.'})
	end.

loop(State0=#state{conn=Conn}) ->
	receive
		%% Stream data.
		%% @todo IsFin is inside Props. But it may not be set once the data was sent.
		{quic, Data, StreamRef, Props} when is_binary(Data) ->
%			ct:pal("DATA ~p props ~p", [StreamRef, Props]),
			parse(State0, Data, StreamRef, Props);
		%% QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED
		{quic, new_stream, StreamRef, #{flags := Flags}} ->
%			ct:pal("new_stream ~p flags ~p", [StreamRef, Flags]),
			ok = quicer:setopt(StreamRef, active, true),
			State = stream_new_remote(State0, StreamRef, Flags),
			loop(State);
		%% QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE
		{quic, stream_closed, StreamRef, Flags} ->
%			ct:pal("stream_closed ~p flags ~p", [StreamRef, Flags]),
			State = stream_closed(State0, StreamRef, Flags),
			loop(State);
		%% QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE
		%%
		%% Connection closed.
		{quic, closed, Conn, _Flags} ->
			quicer:close_connection(Conn),
			%% @todo terminate here?
			ok;
		%%
		%% The following events are currently ignored either because
		%% I do not know what they do or because we do not need to
		%% take action.
		%%
		%% QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT
		{quic, transport_shutdown, Conn, _Flags} ->
			%% @todo Why isn't it BY_PEER when using curl?
			loop(State0);
		%% QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN
		{quic, peer_send_shutdown, _StreamRef, undefined} ->
%			ct:pal("peer_send_shutdown ~p", [StreamRef]),
			loop(State0);
		%% QUIC_STREAM_EVENT_SEND_SHUTDOWN_COMPLETE
		{quic, send_shutdown_complete, _StreamRef, _IsGraceful} ->
			loop(State0);
		%% Messages pertaining to a stream.
		{{Pid, StreamRef}, Msg} when Pid =:= self() ->
			loop(info(State0, StreamRef, Msg));
		%% Exit signal from children.
		Msg = {'EXIT', Pid, _} ->
			loop(down(State0, Pid, Msg));
		Msg ->
			ct:pal("cowboy msg ~p", [Msg]),
			loop(State0)
	end.

parse(State=#state{streams=Streams, opts=Opts}, Data, StreamRef, Props) ->
	case Streams of
		#{StreamRef := Stream=#stream{buffer= <<>>}} ->
			parse1(State, Data, Stream, Props);
		#{StreamRef := Stream=#stream{buffer=Buffer}} ->
			%% @todo OK we should only keep the StreamRef forward
			%%       and update the stream in the state here.
			Stream1 = Stream#stream{buffer= <<>>},
			parse1(stream_update(State, Stream1),
				<<Buffer/binary, Data/binary>>, Stream1, Props);
		%% Pending data for a stream that has been reset. Ignore.
		%% @todo Maybe keep a few pending to ignore this and stream process messages.
		#{} ->
			case is_lingering_stream(State, StreamRef) of
				true ->
					ok;
				false ->
					%% We avoid logging the data as it could be quite large.
					cowboy:log(warning, "Received data for unknown stream ~p.",
						[StreamRef], Opts)
			end,
			loop(State)
	end.

%% @todo Swap Data and Stream/StreamRef.
parse1(State, Data, Stream=#stream{status=header}, Props) ->
	parse_unidirectional_stream_header(State, Data, Stream, Props);
parse1(State, Data, Stream=#stream{status={data, Len}, ref=StreamRef}, Props) ->
	DataLen = byte_size(Data),
	if
		DataLen < Len ->
			IsFin = is_fin(Props, <<>>),
			loop(frame(State, Stream#stream{status={data, Len - DataLen}}, {data, Data}, IsFin));
		true ->
			<<Data1:Len/binary, Rest/bits>> = Data,
			IsFin = is_fin(Props, Rest),
			parse(frame(State, Stream#stream{status=normal}, {data, Data1}, IsFin),
				Rest, StreamRef, Props)
	end;
%% @todo Clause that discards receiving data for aborted streams.
parse1(State, Data, Stream=#stream{ref=StreamRef}, Props) ->
	case cow_http3:parse(Data) of
		{ok, Frame, Rest} ->
			IsFin = is_fin(Props, Rest),
%			ct:pal("parse1 Frame= ~p Rest= ~p", [Frame, Rest]),
			parse(frame(State, Stream, Frame, IsFin), Rest, StreamRef, Props);
		{more, Frame, Len} ->
			IsFin = is_fin(Props, <<>>),
			case IsFin of
				nofin ->
					loop(frame(State, Stream#stream{status={data, Len}}, Frame, nofin));
				fin ->
					terminate(State, {connection_error, h3_frame_error,
						'Last frame on stream was truncated. (RFC9114 7.1)'})
			end;
		{ignore, Rest} ->
			parse(ignored_frame(State, Stream), Rest, StreamRef, Props);
		Error = {connection_error, _, _} ->
			terminate(State, Error);
		more when Data =:= <<>> ->
			loop(stream_update(State, Stream#stream{buffer=Data}));
		more ->
			IsFin = is_fin(Props, <<>>),
			case IsFin of
				nofin ->
					loop(stream_update(State, Stream#stream{buffer=Data}));
				fin ->
					terminate(State, {connection_error, h3_frame_error,
						'Last frame on stream was truncated. (RFC9114 7.1)'})
			end
	end.

%% We may receive multiple frames in a single QUIC packet.
%% The FIN flag applies to the QUIC packet, not to the frame.
%% We must therefore only consider the frame to have a FIN
%% flag if there's no data remaining to be read.
is_fin(#{flags := Flags}, Rest) ->
	case Flags band ?QUIC_RECEIVE_FLAG_FIN of
		?QUIC_RECEIVE_FLAG_FIN when Rest =:= <<>> -> fin;
		_ -> nofin
	end.

parse_unidirectional_stream_header(State0=#state{http3_machine=HTTP3Machine0},
		Data, Stream0=#stream{ref=StreamRef}, Props) ->
	case cow_http3:parse_unidi_stream_header(Data) of
		{ok, Type, Rest} when Type =:= control; Type =:= encoder; Type =:= decoder ->
			case cow_http3_machine:set_unidi_remote_stream_type(
					StreamRef, Type, HTTP3Machine0) of
				{ok, HTTP3Machine} ->
					State = State0#state{http3_machine=HTTP3Machine},
					Stream = Stream0#stream{status=normal},
					parse(stream_update(State, Stream), Rest, StreamRef, Props);
				{error, Error={connection_error, _, _}, HTTP3Machine} ->
					terminate(State0#state{http3_machine=HTTP3Machine}, Error)
			end;
		{ok, push, _} ->
			terminate(State0, {connection_error, h3_stream_creation_error,
				'Only servers can push. (RFC9114 6.2.2)'});
		%% Unknown stream types must be ignored. We choose to abort the
		%% stream instead of reading and discarding the incoming data.
		{undefined, _} ->
			loop(stream_abort_receive(State0, Stream0, h3_stream_creation_error))
	end.

frame(State=#state{http3_machine=HTTP3Machine0}, Stream=#stream{ref=StreamRef}, Frame, IsFin) ->
%	ct:pal("cowboy frame ~p ~p", [Frame, IsFin]),
	case cow_http3_machine:frame(Frame, IsFin, StreamRef, HTTP3Machine0) of
		{ok, HTTP3Machine} ->
			State#state{http3_machine=HTTP3Machine};
		{ok, {data, Data}, HTTP3Machine} ->
			data_frame(State#state{http3_machine=HTTP3Machine}, Stream, IsFin, Data);
		%% @todo I don't think we need the IsFin in the {headers tuple.
		{ok, {headers, IsFin, Headers, PseudoHeaders, BodyLen}, HTTP3Machine} ->
			headers_frame(State#state{http3_machine=HTTP3Machine},
				Stream, IsFin, Headers, PseudoHeaders, BodyLen);
		{ok, {headers, IsFin, Headers, PseudoHeaders, BodyLen},
				{DecoderRef, DecData}, HTTP3Machine} ->
			%% Send the decoder data.
			{ok, _} = quicer:send(DecoderRef, DecData),
			headers_frame(State#state{http3_machine=HTTP3Machine},
				Stream, IsFin, Headers, PseudoHeaders, BodyLen);
		{ok, {trailers, _Trailers}, HTTP3Machine} ->
			%% @todo Propagate trailers.
			State#state{http3_machine=HTTP3Machine};
		{ok, GoAway={goaway, _}, HTTP3Machine} ->
			goaway(State#state{http3_machine=HTTP3Machine}, GoAway);
		{error, Error={stream_error, _Reason, _Human}, HTTP3Machine} ->
			reset_stream(State#state{http3_machine=HTTP3Machine}, StreamRef, Error);
		{error, Error={connection_error, _, _}, HTTP3Machine} ->
			terminate(State#state{http3_machine=HTTP3Machine}, Error)
	end.

data_frame(State=#state{opts=Opts, streams=Streams},
		Stream=#stream{ref=StreamRef, state=StreamState0}, IsFin, Data) ->
	try cowboy_stream:data(StreamRef, IsFin, Data, StreamState0) of
		{Commands, StreamState} ->
			commands(State#state{
				streams=Streams#{StreamRef => Stream#stream{state=StreamState}}},
				StreamRef, Commands)
	catch Class:Exception:Stacktrace ->
		cowboy:log(cowboy_stream:make_error_log(data,
			[StreamRef, IsFin, Data, StreamState0],
			Class, Exception, Stacktrace), Opts),
		reset_stream(State, StreamRef, {internal_error, {Class, Exception},
			'Unhandled exception in cowboy_stream:data/4.'})
	end.

%% @todo CONNECT, TRACE.
headers_frame(State, Stream, IsFin, Headers, PseudoHeaders=#{authority := Authority}, BodyLen) ->
	headers_frame_parse_host(State, Stream, IsFin, Headers, PseudoHeaders, BodyLen, Authority);
headers_frame(State, Stream=#stream{ref=StreamRef}, IsFin, Headers, PseudoHeaders, BodyLen) ->
	case lists:keyfind(<<"host">>, 1, Headers) of
		{_, Authority} ->
			headers_frame_parse_host(State, Stream, IsFin, Headers, PseudoHeaders, BodyLen, Authority);
		_ ->
			reset_stream(State, StreamRef, {stream_error, h3_message_error,
				'Requests translated from HTTP/1.1 must include a host header. (RFC7540 8.1.2.3, RFC7230 5.4)'})
	end.

headers_frame_parse_host(State=#state{peer=Peer, sock=Sock},
		Stream=#stream{ref=StreamRef}, IsFin, Headers,
		#{method := Method, scheme := Scheme, path := PathWithQs},
		BodyLen, Authority) ->
	try cow_http_hd:parse_host(Authority) of
		{Host, Port0} ->
			Port = ensure_port(Scheme, Port0),
			try cow_http:parse_fullpath(PathWithQs) of
				{<<>>, _} ->
					reset_stream(State, StreamRef, {stream_error, h3_message_error,
						'The path component must not be empty. (RFC7540 8.1.2.3)'});
				{Path, Qs} ->
					Req = #{
						ref => quic, %% @todo Ref,
						pid => self(),
						streamid => StreamRef,
						peer => Peer,
						sock => Sock,
						cert => undefined, %Cert, %% @todo
						method => Method,
						scheme => Scheme,
						host => Host,
						port => Port,
						path => Path,
						qs => Qs,
						version => 'HTTP/3',
						headers => headers_to_map(Headers, #{}),
						has_body => IsFin =:= nofin,
						body_length => BodyLen
					},
					%% We add the protocol information for extended CONNECTs. @todo
%					Req = case PseudoHeaders of
%						#{protocol := Protocol} -> Req1#{protocol => Protocol};
%						_ -> Req1
%					end,
					headers_frame(State, Stream, Req)
			catch _:_ ->
				reset_stream(State, StreamRef, {stream_error, h3_message_error,
					'The :path pseudo-header is invalid. (RFC7540 8.1.2.3)'})
			end
	catch _:_ ->
		reset_stream(State, StreamRef, {stream_error, h3_message_error,
			'The :authority pseudo-header is invalid. (RFC7540 8.1.2.3)'})
	end.

%% @todo Copied from cowboy_http2.
%% @todo Remove "http"? Probably.
ensure_port(<<"http">>, undefined) -> 80;
ensure_port(<<"https">>, undefined) -> 443;
ensure_port(_, Port) -> Port.

%% @todo Copied from cowboy_http2.
%% This function is necessary to properly handle duplicate headers
%% and the special-case cookie header.
headers_to_map([], Acc) ->
	Acc;
headers_to_map([{Name, Value}|Tail], Acc0) ->
	Acc = case Acc0 of
		%% The cookie header does not use proper HTTP header lists.
		#{Name := Value0} when Name =:= <<"cookie">> ->
			Acc0#{Name => << Value0/binary, "; ", Value/binary >>};
		#{Name := Value0} ->
			Acc0#{Name => << Value0/binary, ", ", Value/binary >>};
		_ ->
			Acc0#{Name => Value}
	end,
	headers_to_map(Tail, Acc).

headers_frame(State=#state{opts=Opts, streams=Streams},
		Stream=#stream{ref=StreamRef}, Req) ->
ct:pal("req ~p", [Req]),
	try cowboy_stream:init(StreamRef, Req, Opts) of
		{Commands, StreamState} ->
%logger:error("~p", [Commands]),
%logger:error("~p", [StreamState]),
			commands(State#state{
				streams=Streams#{StreamRef => Stream#stream{state=StreamState}}},
				StreamRef, Commands)
	catch Class:Exception:Stacktrace ->
		cowboy:log(cowboy_stream:make_error_log(init,
			[StreamRef, Req, Opts],
			Class, Exception, Stacktrace), Opts),
		reset_stream(State, StreamRef, {internal_error, {Class, Exception},
			'Unhandled exception in cowboy_stream:init/3.'})
	end.

%% Erlang messages.

down(State0=#state{opts=Opts, children=Children0}, Pid, Msg) ->
	State = case cowboy_children:down(Children0, Pid) of
		%% The stream was terminated already.
		{ok, undefined, Children} ->
			State0#state{children=Children};
		%% The stream is still running.
		{ok, StreamRef, Children} ->
			info(State0#state{children=Children}, StreamRef, Msg);
		%% The process was unknown.
		error ->
			cowboy:log(warning, "Received EXIT signal ~p for unknown process ~p.~n",
				[Msg, Pid], Opts),
			State0
	end,
	if
%% @todo
%		State#state.http2_status =:= closing, State#state.streams =:= #{} ->
%			terminate(State, {stop, normal, 'The connection is going away.'});
		true ->
			State
	end.

info(State=#state{opts=Opts, http3_machine=_HTTP3Machine, streams=Streams}, StreamRef, Msg) ->
%ct:pal("INFO ~p", [Msg]),
	case Streams of
		#{StreamRef := Stream=#stream{state=StreamState0}} ->
			try cowboy_stream:info(StreamRef, Msg, StreamState0) of
				{Commands, StreamState} ->
%ct:pal("~p", [Commands]),
%logger:error("~p ~p", [StreamRef, Streams]),
					commands(State#state{streams=Streams#{StreamRef => Stream#stream{state=StreamState}}},
						StreamRef, Commands)
			catch Class:Exception:Stacktrace ->
				cowboy:log(cowboy_stream:make_error_log(info,
					[StreamRef, Msg, StreamState0],
					Class, Exception, Stacktrace), Opts),
				reset_stream(State, StreamRef, {internal_error, {Class, Exception},
					'Unhandled exception in cowboy_stream:info/3.'})
			end;
		_ ->
			case is_lingering_stream(State, StreamRef) of
				true ->
					ok;
				false ->
					cowboy:log(warning, "Received message ~p for unknown stream ~p.",
						[Msg, StreamRef], Opts)
			end,
			State
	end.

%% Stream handler commands.

commands(State, _, []) ->
	State;
%% Error responses are sent only if a response wasn't sent already.
commands(State=#state{http3_machine=HTTP3Machine}, StreamRef,
		[{error_response, StatusCode, Headers, Body}|Tail]) ->
	%% @todo
%	case cow_http2_machine:get_stream_local_state(StreamRef, HTTP2Machine) of
%		{ok, idle, _} ->
			commands(State, StreamRef, [{response, StatusCode, Headers, Body}|Tail]);
%		_ ->
%			commands(State, StreamRef, Tail)
%	end;
%% Send an informational response.
commands(State0, StreamRef, [{inform, StatusCode, Headers}|Tail]) ->
	State = send_headers(State0, StreamRef, idle, StatusCode, Headers),
	commands(State, StreamRef, Tail);
%% Send response headers.
commands(State0, StreamRef, [{response, StatusCode, Headers, Body}|Tail]) ->
	ct:pal("commands response ~p ~p ~p", [StatusCode, Headers, try iolist_size(Body) catch _:_ -> Body end]),
	State = send_response(State0, StreamRef, StatusCode, Headers, Body),
	commands(State, StreamRef, Tail);
%% Send response headers.
commands(State0, StreamRef, [{headers, StatusCode, Headers}|Tail]) ->
	ct:pal("commands headers ~p ~p", [StatusCode, Headers]),
	State = send_headers(State0, StreamRef, nofin, StatusCode, Headers),
	commands(State, StreamRef, Tail);
%%% Send a response body chunk.
commands(State0, StreamRef, [{data, IsFin, Data}|Tail]) ->
	ct:pal("commands data ~p ~p", [IsFin, try iolist_size(Data) catch _:_ -> Data end]),
	_ = case Data of
		{sendfile, Offset, Bytes, Path} ->
			%% Temporary solution to do sendfile over QUIC.
			{ok, _} = ranch_transport:sendfile(?MODULE, StreamRef,
				Path, Offset, Bytes, []),
			{ok, _} = quicer:send(StreamRef, cow_http3:data(<<>>), send_flag(IsFin));
		_ ->
			{ok, _} = quicer:send(StreamRef, cow_http3:data(Data), send_flag(IsFin))
	end,
	State = maybe_send_is_fin(State0, StreamRef, IsFin),
	commands(State, StreamRef, Tail);
%%% Send trailers.
commands(State=#state{http3_machine=HTTP3Machine0}, StreamRef, [{trailers, Trailers}|Tail]) ->
	ct:pal("commands trailers ~p", [Trailers]),
	HTTP3Machine = case cow_http3_machine:prepare_trailers(
			StreamRef, HTTP3Machine0, maps:to_list(Trailers)) of
		{trailers, HeaderBlock, _EncData, HTTP3Machine1} ->
			ct:pal("trailers"),
			%% @todo EncData!!
			{ok, _} = quicer:send(StreamRef, cow_http3:headers(HeaderBlock), send_flag(fin)),
			HTTP3Machine1;
		{no_trailers, HTTP3Machine1} ->
			ct:pal("no_trailers"),
			{ok, _} = quicer:send(StreamRef, cow_http3:data(<<>>), send_flag(fin)),
			HTTP3Machine1
	end,
	commands(State#state{http3_machine=HTTP3Machine}, StreamRef, Tail);
%% Send a push promise.
%%
%% @todo Responses sent as a result of a push_promise request
%% must not send push_promise frames themselves.
%%
%% @todo We should not send push_promise frames when we are
%% in the closing http2_status.
%commands(State0=#state{socket=Socket, transport=Transport, http3_machine=HTTP3Machine0},
%		StreamRef, [{push, Method, Scheme, Host, Port, Path, Qs, Headers0}|Tail]) ->
%	Authority = case {Scheme, Port} of
%		{<<"http">>, 80} -> Host;
%		{<<"https">>, 443} -> Host;
%		_ -> iolist_to_binary([Host, $:, integer_to_binary(Port)])
%	end,
%	PathWithQs = iolist_to_binary(case Qs of
%		<<>> -> Path;
%		_ -> [Path, $?, Qs]
%	end),
%	PseudoHeaders = #{
%		method => Method,
%		scheme => Scheme,
%		authority => Authority,
%		path => PathWithQs
%	},
%	%% We need to make sure the header value is binary before we can
%	%% create the Req object, as it expects them to be flat.
%	Headers = maps:to_list(maps:map(fun(_, V) -> iolist_to_binary(V) end, Headers0)),
%	%% @todo
%	State = case cow_http2_machine:prepare_push_promise(StreamRef, HTTP3Machine0,
%			PseudoHeaders, Headers) of
%		{ok, PromisedStreamRef, HeaderBlock, HTTP3Machine} ->
%			Transport:send(Socket, cow_http2:push_promise(
%				StreamRef, PromisedStreamRef, HeaderBlock)),
%			headers_frame(State0#state{http3_machine=HTTP2Machine},
%				PromisedStreamRef, fin, Headers, PseudoHeaders, 0);
%		{error, no_push} ->
%			State0
%	end,
%	commands(State, StreamRef, Tail);
%%% Read the request body.
%commands(State0=#state{flow=Flow, streams=Streams}, StreamRef, [{flow, Size}|Tail]) ->
commands(State, StreamRef, [{flow, _Size}|Tail]) ->
	%% @todo We should tell the QUIC stream to increase its window size.
%	#{StreamRef := Stream=#stream{flow=StreamFlow}} = Streams,
%	State = update_window(State0#state{flow=Flow + Size,
%		streams=Streams#{StreamRef => Stream#stream{flow=StreamFlow + Size}}},
%		StreamRef),
	commands(State, StreamRef, Tail);
%% Supervise a child process.
commands(State=#state{children=Children}, StreamRef, [{spawn, Pid, Shutdown}|Tail]) ->
	 commands(State#state{children=cowboy_children:up(Children, Pid, StreamRef, Shutdown)},
		StreamRef, Tail);
%% Error handling.
%commands(State, StreamRef, [Error = {internal_error, _, _}|_Tail]) ->
%	%% @todo Do we want to run the commands after an internal_error?
%	%% @todo Do we even allow commands after?
%	%% @todo Only reset when the stream still exists.
%	reset_stream(State, StreamRef, Error);
%% Upgrade to HTTP/2. This is triggered by cowboy_http2 itself.
%commands(State=#state{socket=Socket, transport=Transport, http2_status=upgrade},
%		StreamRef, [{switch_protocol, Headers, ?MODULE, _}|Tail]) ->
%	%% @todo This 101 response needs to be passed through stream handlers.
%	Transport:send(Socket, cow_http:response(101, 'HTTP/1.1', maps:to_list(Headers))),
%	commands(State, StreamRef, Tail);
%% Use a different protocol within the stream (CONNECT :protocol).
%% @todo Make sure we error out when the feature is disabled.
%commands(State0, StreamRef, [{switch_protocol, Headers, _Mod, _ModState}|Tail]) ->
%	State = info(State0, StreamRef, {headers, 200, Headers}),
%	commands(State, StreamRef, Tail);
%% Set options dynamically.
commands(State, StreamRef, [{set_options, _Opts}|Tail]) ->
	commands(State, StreamRef, Tail);
commands(State, StreamRef, [stop|_Tail]) ->
	ct:pal("stop"),
	%% @todo Do we want to run the commands after a stop?
	%% @todo Do we even allow commands after?
	stop_stream(State, StreamRef);
%% Log event.
commands(State=#state{opts=Opts}, StreamRef, [Log={log, _, _, _}|Tail]) ->
	cowboy:log(Log, Opts),
	commands(State, StreamRef, Tail).

send_response(State0=#state{http3_machine=HTTP3Machine0}, StreamRef, StatusCode, Headers, Body) ->
	Size = case Body of
		{sendfile, _, Bytes0, _} -> Bytes0;
		_ -> iolist_size(Body)
	end,
	case Size of
		0 ->
			State = send_headers(State0, StreamRef, fin, StatusCode, Headers),
			maybe_send_is_fin(State, StreamRef, fin);
		_ ->
			%% @todo Add a test for HEAD to make sure we don't send the body when
			%% returning {response...} from a stream handler (or {headers...} then {data...}).
			%% @todo We must send EncData!
			{ok, _IsFin, HeaderBlock, _EncData, HTTP3Machine}
				= cow_http3_machine:prepare_headers(StreamRef, HTTP3Machine0, nofin,
					#{status => cow_http:status_to_integer(StatusCode)},
					headers_to_list(Headers)),
			%% @todo It might be better to do async sends.
			_ = case Body of
				{sendfile, Offset, Bytes, Path} ->
					{ok, _} = quicer:send(StreamRef, cow_http3:headers(HeaderBlock)),
					%% Temporary solution to do sendfile over QUIC.
					{ok, _} = ranch_transport:sendfile(?MODULE, StreamRef,
						Path, Offset, Bytes, []),
					{ok, _} = quicer:send(StreamRef, cow_http3:data(<<>>), send_flag(fin));
				_ ->
					{ok, _} = quicer:send(StreamRef, [
						cow_http3:headers(HeaderBlock),
						cow_http3:data(Body)
					], send_flag(fin))
			end,
			maybe_send_is_fin(State0#state{http3_machine=HTTP3Machine}, StreamRef, fin)
	end.

maybe_send_is_fin(State=#state{http3_machine=HTTP3Machine0}, StreamRef, fin) ->
	HTTP3Machine = cow_http3_machine:close_bidi_stream_for_sending(StreamRef, HTTP3Machine0),
	State#state{http3_machine=HTTP3Machine};
maybe_send_is_fin(State, _, _) ->
	State.

%% Temporary callback to do sendfile over QUIC.
send(StreamRef, IoData) ->
	case quicer:send(StreamRef, cow_http3:data(IoData)) of
		{ok, _} -> ok;
		Error -> Error
	end.

send_headers(State=#state{http3_machine=HTTP3Machine0},
		StreamRef, IsFin0, StatusCode, Headers) ->
	{ok, IsFin, HeaderBlock, _EncData, HTTP3Machine}
		= cow_http3_machine:prepare_headers(StreamRef, HTTP3Machine0, IsFin0,
			#{status => cow_http:status_to_integer(StatusCode)},
			headers_to_list(Headers)),
	{ok, _} = quicer:send(StreamRef, cow_http3:headers(HeaderBlock), send_flag(IsFin)),
	%% @todo Send _EncData.
	State#state{http3_machine=HTTP3Machine}.

%% The set-cookie header is special; we can only send one cookie per header.
headers_to_list(Headers0=#{<<"set-cookie">> := SetCookies}) ->
	Headers = maps:to_list(maps:remove(<<"set-cookie">>, Headers0)),
	Headers ++ [{<<"set-cookie">>, Value} || Value <- SetCookies];
headers_to_list(Headers) ->
	maps:to_list(Headers).

send_flag(nofin) -> ?QUIC_SEND_FLAG_NONE;
send_flag(fin) -> ?QUIC_SEND_FLAG_FIN.

reset_stream(State0=#state{http3_machine=HTTP3Machine0}, StreamRef, Error) ->
	Reason = case Error of
		{internal_error, _, _} -> h3_internal_error;
		{stream_error, Reason0, _} -> Reason0
	end,
	%% @todo Do we want to close both sides?
	%% @todo Should we close the send side if the receive side was already closed?
	quicer:shutdown_stream(StreamRef, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT,
		cow_http3:error_to_code(Reason), infinity),
	State1 = case cow_http3_machine:reset_stream(StreamRef, HTTP3Machine0) of
		{ok, HTTP3Machine} ->
			terminate_stream(State0#state{http3_machine=HTTP3Machine}, StreamRef, Error);
		{error, not_found} ->
			terminate_stream(State0, StreamRef, Error)
	end,
%% @todo
%	case reset_rate(State1) of
%		{ok, State} ->
%			State;
%		error ->
%			terminate(State1, {connection_error, enhance_your_calm,
%				'Stream reset rate larger than configuration allows. Flood? (CVE-2019-9514)'})
%	end.
	State1.

stop_stream(State0=#state{http3_machine=HTTP3Machine, streams=Streams}, StreamRef) ->
	#{StreamRef := Stream} = Streams,
	%% We abort reading when stopping the stream but only
	%% if the client was not finished sending data.
	State = case cow_http3_machine:get_stream_remote_state(StreamRef, HTTP3Machine) of
		{ok, fin} ->
			State0;
		_ ->
			stream_abort_receive(State0, Stream, h3_no_error)
	end,
	%% Then we may need to send a response or terminate it
	%% if the stream handler did not do so already.
	case cow_http3_machine:get_stream_local_state(StreamRef, HTTP3Machine) of
		%% When the stream terminates normally (without resetting the stream)
		%% and no response was sent, we need to send a proper response back to the client.
		{ok, idle} ->
			info(State, StreamRef, {response, 204, #{}, <<>>});
		%% When a response was sent but not terminated, we need to close the stream.
		%% We send a final DATA frame to complete the stream.
		{ok, nofin} ->
			ct:pal("error nofin"),
			info(State, StreamRef, {data, fin, <<>>});
		%% When a response was sent fully we can terminate the stream,
		%% regardless of the stream being in half-closed or closed state.
		_ ->
			terminate_stream(State, StreamRef, h3_no_error)
	end.

terminate_stream(State=#state{streams=Streams0, children=Children0}, StreamRef, Reason) ->
	case maps:take(StreamRef, Streams0) of
		{#stream{state=StreamState}, Streams} ->
			terminate_stream_handler(State, StreamRef, Reason, StreamState),
			Children = cowboy_children:shutdown(Children0, StreamRef),
			stream_linger(State#state{streams=Streams, children=Children}, StreamRef);
		error ->
			State
	end.

terminate_stream_handler(#state{opts=Opts}, StreamRef, Reason, StreamState) ->
	try
		cowboy_stream:terminate(StreamRef, Reason, StreamState)
	catch Class:Exception:Stacktrace ->
		cowboy:log(cowboy_stream:make_error_log(terminate,
			[StreamRef, Reason, StreamState],
			Class, Exception, Stacktrace), Opts)
	end.

ignored_frame(State=#state{http3_machine=HTTP3Machine0}, #stream{ref=StreamRef}) ->
	case cow_http3_machine:ignored_frame(StreamRef, HTTP3Machine0) of
		{ok, HTTP3Machine} ->
			State#state{http3_machine=HTTP3Machine};
		{error, Error={connection_error, _, _}, HTTP3Machine} ->
			terminate(State#state{http3_machine=HTTP3Machine}, Error)
	end.

stream_abort_receive(State, Stream=#stream{ref=StreamRef}, Reason) ->
	quicer:shutdown_stream(StreamRef, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE,
		cow_http3:error_to_code(Reason), infinity),
	stream_update(State, Stream#stream{status=discard}).

%% @todo Graceful connection shutdown.
%% We terminate the connection immediately if it hasn't fully been initialized.
goaway(State, {goaway, _}) ->
	terminate(State, {stop, goaway, 'The connection is going away.'}).

terminate(State=#state{conn=Conn, %http3_status=Status,
		%http3_machine=HTTP3Machine,
		streams=Streams, children=Children}, Reason) ->
%	if
%		Status =:= connected; Status =:= closing_initiated ->
%% @todo
%			{ok, _} = quicer:send(ControlRef, cow_http3:goaway(
%				cow_http3_machine:get_last_streamid(HTTP3Machine))),
		%% We already sent the GOAWAY frame.
%		Status =:= closing ->
%			ok
%	end,
	terminate_all_streams(State, maps:to_list(Streams), Reason),
	cowboy_children:terminate(Children),
%	terminate_linger(State),
	quicer:shutdown_connection(Conn,
		?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE,
		cow_http3:error_to_code(terminate_reason(Reason))),
	exit({shutdown, Reason}).

terminate_reason({connection_error, Reason, _}) -> Reason;
terminate_reason({stop, _, _}) -> h3_no_error.
%terminate_reason({socket_error, _, _}) -> internal_error;
%terminate_reason({internal_error, _, _}) -> internal_error.


terminate_all_streams(_, [], _) ->
	ok;
terminate_all_streams(State, [{StreamID, #stream{state=StreamState}}|Tail], Reason) ->
	terminate_stream_handler(State, StreamID, Reason, StreamState),
	terminate_all_streams(State, Tail, Reason).





stream_new_remote(State=#state{http3_machine=HTTP3Machine0, streams=Streams}, StreamRef, Flags) ->
	{HTTP3Machine, Status} = case quicer:is_unidirectional(Flags) of
		true ->
			{cow_http3_machine:init_unidi_stream(StreamRef, unidi_remote, HTTP3Machine0),
				header};
		false ->
			{cow_http3_machine:init_bidi_stream(StreamRef, HTTP3Machine0),
				normal}
	end,
	Stream = #stream{ref=StreamRef, status=Status},
%	ct:pal("new stream ~p ~p", [Stream, HTTP3Machine]),
	State#state{http3_machine=HTTP3Machine, streams=Streams#{StreamRef => Stream}}.

stream_closed(State=#state{http3_machine=HTTP3Machine0, streams=Streams0},
		StreamRef, _Flags) ->
	case cow_http3_machine:close_stream(StreamRef, HTTP3Machine0) of
		{ok, HTTP3Machine} ->
			%% @todo Some streams may not be bidi or remote.
			Streams = maps:remove(StreamRef, Streams0),
			%% @todo terminate stream
			State#state{http3_machine=HTTP3Machine, streams=Streams};
		{error, Error={connection_error, _, _}, HTTP3Machine} ->
			terminate(State#state{http3_machine=HTTP3Machine}, Error)
	end.

stream_update(State=#state{streams=Streams}, Stream=#stream{ref=StreamRef}) ->
	State#state{streams=Streams#{StreamRef => Stream}}.

stream_linger(State=#state{lingering_streams=Lingering0}, StreamRef) ->
	%% We only keep up to 100 streams in this state. @todo Make it configurable?
	Lingering = [StreamRef|lists:sublist(Lingering0, 100 - 1)],
	State#state{lingering_streams=Lingering}.

is_lingering_stream(#state{lingering_streams=Lingering}, StreamRef) ->
	lists:member(StreamRef, Lingering).