%% Copyright (c) 2011-2017, Loïc Hoguin <essen@ninenines.eu>
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

-module(cowboy).

-export([start_clear/3]).
-export([start_tls/3]).
-export([start_quic/2]).
-export([start_quic_test/0]).
-export([stop_listener/1]).
-export([set_env/3]).

%% Internal.
-export([log/2]).
-export([log/4]).

-type opts() :: cowboy_http:opts() | cowboy_http2:opts().
-export_type([opts/0]).

-type fields() :: [atom()
	| {atom(), cowboy_constraints:constraint() | [cowboy_constraints:constraint()]}
	| {atom(), cowboy_constraints:constraint() | [cowboy_constraints:constraint()], any()}].
-export_type([fields/0]).

-type http_headers() :: #{binary() => iodata()}.
-export_type([http_headers/0]).

-type http_status() :: non_neg_integer() | binary().
-export_type([http_status/0]).

-type http_version() :: 'HTTP/2' | 'HTTP/1.1' | 'HTTP/1.0'.
-export_type([http_version/0]).

-spec start_clear(ranch:ref(), ranch:opts(), opts())
	-> {ok, pid()} | {error, any()}.
start_clear(Ref, TransOpts0, ProtoOpts0) ->
	TransOpts1 = ranch:normalize_opts(TransOpts0),
	{TransOpts, ConnectionType} = ensure_connection_type(TransOpts1),
	ProtoOpts = ProtoOpts0#{connection_type => ConnectionType},
	ranch:start_listener(Ref, ranch_tcp, TransOpts, cowboy_clear, ProtoOpts).

-spec start_tls(ranch:ref(), ranch:opts(), opts())
	-> {ok, pid()} | {error, any()}.
start_tls(Ref, TransOpts0, ProtoOpts0) ->
	TransOpts1 = ranch:normalize_opts(TransOpts0),
	SocketOpts = maps:get(socket_opts, TransOpts1, []),
	TransOpts2 = TransOpts1#{socket_opts => [
		{next_protocols_advertised, [<<"h2">>, <<"http/1.1">>]},
		{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
	|SocketOpts]},
	{TransOpts, ConnectionType} = ensure_connection_type(TransOpts2),
	ProtoOpts = ProtoOpts0#{connection_type => ConnectionType},
	ranch:start_listener(Ref, ranch_ssl, TransOpts, cowboy_tls, ProtoOpts).

%% @todo Experimental function to start a barebone QUIC listener.
%%       This will need to be reworked to be closer to Ranch
%%       listeners and provide equivalent features.
-spec start_quic(_, _) -> todo.
start_quic(TransOpts, ProtoOpts) ->
	{ok, _} = application:ensure_all_started(quicer),
	Parent = self(),
	Port = 4567,
	SocketOpts0 = maps:get(socket_opts, TransOpts, []),
	SocketOpts = [
		{alpn, ["h3"]}, %% @todo Why not binary?
		{peer_unidi_stream_count, 3}, %% We only need control and QPACK enc/dec.
		{peer_bidi_stream_count, 100}
	|SocketOpts0],
	{ok, Listener} = quicer:listen(Port, SocketOpts),
	ct:pal("listen ~p", [Listener]),
	_ListenerPid = spawn(fun AcceptLoop() ->
		{ok, Conn} = quicer:accept(Listener, []),
		ct:pal("accept ~p", [Conn]),
		{ok, Conn} = quicer:handshake(Conn),
		ct:pal("handshake ~p", [Conn]),
		Pid = spawn(fun() ->
			receive go -> ok end,
			process_flag(trap_exit, true), %% @todo Only if supervisor though.
			try cowboy_http3:init(Parent, Conn, ProtoOpts)
			catch
				exit:{shutdown,_} -> ok;
				C:E:S -> ct:pal("CRASH ~p:~p:~p", [C,E,S])
			end
		end),
		ok = quicer:controlling_process(Conn, Pid),
		Pid ! go,
		AcceptLoop()
	end),
	{ok, Listener}.

-spec start_quic_test() -> ok.
start_quic_test() ->
	start_quic(#{
		socket_opts => [
			{cert, "deps/quicer/test/quicer_SUITE_data/cert.pem"},
			{key, "deps/quicer/test/quicer_SUITE_data/key.pem"}
		]
	}, #{
		env => #{dispatch => cowboy_router:compile([
			{"localhost", [
				{"/", quic_hello_h, []}
			]}
		])}
	}).

ensure_connection_type(TransOpts=#{connection_type := ConnectionType}) ->
	{TransOpts, ConnectionType};
ensure_connection_type(TransOpts) ->
	{TransOpts#{connection_type => supervisor}, supervisor}.

-spec stop_listener(ranch:ref()) -> ok | {error, not_found}.
stop_listener(Ref) ->
	ranch:stop_listener(Ref).

-spec set_env(ranch:ref(), atom(), any()) -> ok.
set_env(Ref, Name, Value) ->
	Opts = ranch:get_protocol_options(Ref),
	Env = maps:get(env, Opts, #{}),
	Opts2 = maps:put(env, maps:put(Name, Value, Env), Opts),
	ok = ranch:set_protocol_options(Ref, Opts2).

%% Internal.

-spec log({log, logger:level(), io:format(), list()}, opts()) -> ok.
log({log, Level, Format, Args}, Opts) ->
	log(Level, Format, Args, Opts).

-spec log(logger:level(), io:format(), list(), opts()) -> ok.
log(Level, Format, Args, #{logger := Logger})
		when Logger =/= error_logger ->
	_ = Logger:Level(Format, Args),
	ok;
%% We use error_logger by default. Because error_logger does
%% not have all the levels we accept we have to do some
%% mapping to error_logger functions.
log(Level, Format, Args, _) ->
	Function = case Level of
		emergency -> error_msg;
		alert -> error_msg;
		critical -> error_msg;
		error -> error_msg;
		warning -> warning_msg;
		notice -> warning_msg;
		info -> info_msg;
		debug -> info_msg
	end,
	error_logger:Function(Format, Args).
