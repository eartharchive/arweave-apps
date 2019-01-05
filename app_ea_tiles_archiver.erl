-module(app_ea_tiles_archiver).

-export([add/2, start/1, start/2, start/3,
	 start_archiving/3, stop/1, print_state/1, print_index/1, generate_index/1, clear_to_index/1]).

-include("../ar.hrl").

-include_lib("eunit/include/eunit.hrl").

%%% Starts a server that takes, signs and submits transactions to a node.
%%% The server also handles waiting until the transaction is sufficiently
%%% 'buried' in blocks, before sending the next one.
%%%
%%% Note! The transactions are never properly confirmed (by checking that they
%%% ended up in a block not on a fork), so it's possible that one transaction
%%% gets lost and the queue continues succeeding in submitting the following
%%% transactions.
%%%
%%% Earth Archive addition. 
%%% start_archiving/3 takes the Queue PID the folder to archive and the indexwallet
%%% the index wallet is used to tag indexes. As accounts are used as taggers in the PoC.
%%% The folder expects a Z, X, Y folder format for map tiles and it will put that data on tags.
%%% As well there is an option to generate another index transaction to connect to all the archived tiles.
%%% This is a Proof of Concept in order to test the end to end flow.
%%% 1) Get a full raster into QGIS and tile it.
%%% 2) Archived the folder into arweave
%%% 3) Show the tiles on leaflet

-record(state,
	{node, wallet, previous_tx = none,
	 previous_tx_tag_name = undefined, to_index = [],
	 index_wallet,
	 current_index}).

%% How many blocks deep should be bury a TX before continuing?
-define(CONFIRMATION_DEPTH, 1).

%% How many ms should we wait between checking the current height.
-ifdef(DEBUG).

-define(POLL_INTERVAL_MS, 250).

-else.

-define(POLL_INTERVAL_MS, 15 * 1000).

-endif.

%% @doc Takes a wallet, and optionally a node (if none is supplied, the local node
%% is used).
start(Wallet) ->
    start(whereis(http_entrypoint_node), Wallet).

start(Node, Wallet) -> start(Node, Wallet, undefined).

start(Node, Wallet, PreviousTXTagName) ->
    spawn(fun () ->
		  server(#state{node = Node, wallet = Wallet,
				previous_tx_tag_name = PreviousTXTagName})
	  end).

%% @doc Add an unsigned TX to the queue. The server will then sign it and submit it.
add(PID, TX) -> PID ! {add_tx, TX}.


start_archiving(PID, Folder, IndexWallet) ->
    PID ! {start_archiving, PID, Folder, IndexWallet}.

stop(PID) -> PID ! stop.

print_state(PID) -> PID ! print.

print_index(PID) -> PID ! index.

generate_index(PID) -> PID ! generate_index.

clear_to_index(PID) -> PID ! clear_to_index.

server(S) ->
    receive
      stop -> ok;
      {add_tx, TX} -> NewS = send_tx(S, TX), server(NewS);
      {start_archiving, PID, Folder, IndexWallet} ->
	  	InitIndexS = init_index(S, IndexWallet),
	  	NewS = archive(PID, InitIndexS, Folder),
	  	server(NewS);
	  print ->
		  ar:report([{print_state, S#state.to_index}]),
		  server(S);
	  index ->
		  ar:report([{print_index, S#state.current_index}]),
		  server(S);
	  generate_index ->
		  NewS = do_generate_index(S),
		  server(NewS);
	  clear_to_index ->
		  NewS = S#state{to_index = []},
		  server(NewS)
    end.

init_index(S, IndexWallet) ->
    S#state{index_wallet = IndexWallet}.

%% @doc Start archiving folder tiles
archive(PID, S, Folder) ->
	ar:report([{ea_tiles_path_to_archive, Folder}]),
    {ok, ZFolders} = file:list_dir(Folder),
    ar:report([{storing_ea_tiles, ZFolders}]),
    lists:foreach(fun (Z) ->
			  ar:report([{zoom_level, Z}]),
			  ZPath = Folder ++ "/" ++ Z,
			  {ok, XFolders} = file:list_dir(ZPath),
			  lists:foreach(fun (X) ->
						XPath = ZPath ++ "/" ++ X,
						ar:report([{x_path, XPath}]),
						{ok, YFiles} =
						     file:list_dir(XPath),
						ar:report([{y_files, YFiles}]),
						lists:foreach(fun (Y) -> 
							YPath = XPath ++ "/" ++ Y,
							ar:report([{y_path, YPath}]),
							TX = file_to_tx(Z, X, Y, YPath),
							PID ! {add_tx, TX},
							ar:report([{tx_to_add, TX}])
						end,
						YFiles)
					end,
					XFolders)
		  end,
		  ZFolders),
	S.

%% @doc Generate an Arweave transaction for an IA item.
file_to_tx(Z, X, Y, FilePath) ->
	%% attributon hard coded for PoC is all OGH data
	{ok, File} = file:read_file(FilePath),

    #tx {
        tags =
            [
                {"app_name", "ArchivedEarth"},
                {"attribution", "Tomislav Hengl, & Ichsani Wheeler. (2018). Soil organic carbon content in x 5 g / kg at 6 standard depths (0, 10, 30, 60, 100 and 200 cm) at 250 m resolution (Version v0.1) [Data set]. Zenodo. http://doi.org/10.5281/zenodo.1475458"},
                {"Content-Type", "image/png"},
				{"Z", Z},
				{"X", X},
				{"Y", Y},
				{"EATYPE", "tile"}
            ], 
        data = File
    }.

do_generate_index(S) ->
    ar:report([{do_generate_index_to_index, S#state.to_index}]), 
	CurrentIndex = lists:map(fun ({TxId, TxTags, TxCost}) -> 
		[
					{"app_name", "ArchivedEarth"},
					{"attribution", Attribution},
					{"Content-Type", "image/png"},
					{"Z", Z},
					{"X", X},
					{"Y", Y},
					{"EATYPE", Type}
		] = TxTags,
		#{tx => TxId, z => ar_util:encode(Z), x => ar_util:encode(X), y => ar_util:encode(Y), eatype => ar_util:encode(Type)}
		end,
		S#state.to_index),
	JsonOutput = jiffy:encode(CurrentIndex),
	ar:report([json_output, JsonOutput]),
	%CurrentIndex = jiffy:encode(S#state.to_index),
	send_index_tx(S, json_to_index(JsonOutput)). 
	%S.

json_to_index(Json) ->
	ar:report([json_to_index, Json]),

    #tx {
        tags =
            [
                {"app_name", "ArchivedEarth"},
                {"Content-Type", "application/json"},
				{"EATYPE", "tiles"}
            ], 
        data = Json
    }.

archive_index(S) ->
	ar:report([{to_index, S#state.to_index}]), 
	CurrentIndex = jiffy:encode(S#state.to_index),
	ar:report([{current_index, CurrentIndex}]), 
	S#state{current_index = CurrentIndex}.

%% @doc Send a tx to the network and wait for it to be confirmed.
send_tx(S, TX) ->
    Addr = ar_wallet:to_address(S#state.wallet),
    Price =
	ar_tx:calculate_min_tx_cost(byte_size(TX#tx.data),
				    ar_node:get_current_diff(S#state.node),
				    ar_node:get_wallet_list(S#state.node),
				    TX#tx.target),
    Tags = tx_tags(TX, S#state.previous_tx,
		   S#state.previous_tx_tag_name),
    SignedTX = ar_tx:sign(TX#tx{last_tx =
				    ar_node:get_last_tx(S#state.node, Addr),
				reward = Price, tags = Tags},
			  S#state.wallet),
    ar_node:add_tx(S#state.node, SignedTX),
    ar:report([{app, ?MODULE},
	       {submitted_tx, ar_util:encode(SignedTX#tx.id)},
	       {cost, SignedTX#tx.reward / (?AR(1))},
	       {size, byte_size(SignedTX#tx.data)}]),
    timer:sleep(ar_node_utils:calculate_delay(byte_size(TX#tx.data))),
    StartHeight = get_current_height(S),
    wait_for_block(S#state { previous_tx = SignedTX#tx.id, to_index = S#state.to_index ++ [{ar_util:encode(SignedTX#tx.id), SignedTX#tx.tags, SignedTX#tx.reward / (?AR(1))}]}, StartHeight + ?CONFIRMATION_DEPTH).
	

send_index_tx(S, TX) ->
    Addr = ar_wallet:to_address(S#state.index_wallet),
    Price =
	ar_tx:calculate_min_tx_cost(byte_size(TX#tx.data),
				    ar_node:get_current_diff(S#state.node),
				    ar_node:get_wallet_list(S#state.node),
				    TX#tx.target),
    Tags = tx_tags(TX, S#state.previous_tx,
		   S#state.previous_tx_tag_name),
    SignedTX = ar_tx:sign(TX#tx{last_tx =
				    ar_node:get_last_tx(S#state.node, Addr),
				reward = Price, tags = Tags},
			  S#state.wallet),
    ar_node:add_tx(S#state.node, SignedTX),
    ar:report([{app, ?MODULE},
	       {submitted_tx, ar_util:encode(SignedTX#tx.id)},
	       {cost, SignedTX#tx.reward / (?AR(1))},
	       {size, byte_size(SignedTX#tx.data)}]),
	FileName = "tile-indexes/ea_tile_index_" ++ binary_to_list(ar_util:encode(SignedTX#tx.id)) ++ ".json",
	filelib:ensure_dir(FileName),
	file:write_file(FileName, TX#tx.data),
    timer:sleep(ar_node_utils:calculate_delay(byte_size(TX#tx.data))),
	StartHeight = get_current_height(S),
	wait_for_block(S#state { previous_tx = SignedTX#tx.id }, StartHeight + ?CONFIRMATION_DEPTH).


tx_tags(TX, none, _) -> TX#tx.tags;
tx_tags(TX, _, undefined) -> TX#tx.tags;
tx_tags(TX, PreviousTXID, PreviousTXTagName) ->
    TX#tx.tags ++
      [{PreviousTXTagName, ar_util:encode(PreviousTXID)}].

%% @doc Wait until a given block height has been reached.
wait_for_block(S, TargetH) ->
    CurrentH = get_current_height(S),
    if CurrentH >= TargetH -> S;
       true ->
	   timer:sleep(?POLL_INTERVAL_MS),
	   wait_for_block(S, TargetH)
    end.

%% @doc Take a server state and return the current block height.
get_current_height(S) ->
    length(ar_node:get_hash_list(S#state.node)).

%%% TESTS

queue_single_tx_test_() ->
    {timeout, 60,
     fun () ->
	     ar_storage:clear(),
	     Wallet = {_Priv1, Pub1} = ar_wallet:new(),
	     Addr = crypto:strong_rand_bytes(32),
	     Bs = ar_weave:init([{ar_wallet:to_address(Pub1),
				  ?AR(10000), <<>>}]),
	     Node1 = ar_node:start([], Bs),
	     Queue = start(Node1, Wallet),
	     receive  after 500 -> ok end,
	     add(Queue, ar_tx:new(Addr, ?AR(1), ?AR(1000), <<>>)),
	     receive  after 500 -> ok end,
	     lists:foreach(fun (_) ->
				   ar_node:mine(Node1),
				   receive  after 500 -> ok end
			   end,
			   lists:seq(1, ?CONFIRMATION_DEPTH)),
	     ?assertEqual((?AR(1000)),
			  (ar_node:get_balance(Node1, Addr)))
     end}.

queue_double_tx_test_() ->
    {timeout, 60,
     fun () ->
	     ar_storage:clear(),
	     Wallet = {_Priv1, Pub1} = ar_wallet:new(),
	     Addr = crypto:strong_rand_bytes(32),
	     Bs = ar_weave:init([{ar_wallet:to_address(Pub1),
				  ?AR(10000), <<>>}]),
	     Node1 = ar_node:start([], Bs),
	     Queue = start(Node1, Wallet),
	     receive  after 500 -> ok end,
	     add(Queue, ar_tx:new(Addr, ?AR(1), ?AR(1000), <<>>)),
	     add(Queue, ar_tx:new(Addr, ?AR(1), ?AR(1000), <<>>)),
	     receive  after 500 -> ok end,
	     lists:foreach(fun (_) ->
				   ar_node:mine(Node1),
				   receive  after 500 -> ok end
			   end,
			   lists:seq(1, (?CONFIRMATION_DEPTH) * 4)),
	     ?assertEqual((?AR(2000)),
			  (ar_node:get_balance(Node1, Addr)))
     end}.
