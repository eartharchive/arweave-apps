# arweave-apps
archive.earth Arweave Applications

Earth Archive addition to the standard arweave app_queue app. 
start_archiving/3 takes the Queue PID the folder to archive and the indexwallet
the index wallet is used to tag indexes. As accounts are used as taggers in the PoC.
The folder expects a Z, X, Y folder format for map tiles and it will put that data on tags.
As well there is an option to generate another index transaction to connect to all the archived tiles.
This is a Proof of Concept in order to test the end to end flow.
1) Get a full raster into QGIS and tile it.
2) Archived the folder into arweave
3) Show the tiles on leaflet

Manual usage on the erlang arweave terminal:

rr("src/*"). 

Walle = ar_wallet:load_keyfile("route_to_walle_key"). 
Queue = app_ea_tiles_archiver:start(Wallet).

WalletIndex = ar_wallet:load_keyfile("route_to_index_tiles_wallet"). 

app_ea_tiles_archiver:start_archiving(Queue, "route to folder containing Map Tiles", WalletIndex). 

app_ea_tiles_archiver:print_index(Queue).
