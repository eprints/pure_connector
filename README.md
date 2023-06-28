# Pure Connector
Handler files to allow Pure's CRIS to create and modify items on EPrints

## Usage Instructions
1. Deploy the `plugins/PDA` directory (either by copying of symlinking to `<EPRINTS_PATH>/site_lib/plugins/PDA`.
2. If you are running EPrints 3.4+, make sure `site_lib` is listed in your `<EPRINTS_PATH>/flavours/pub_lib/inc` file.
3. Copy the configuration file `cfg.d/z\_pda\_handler.pl` to the file `<EPRINTS_PATH>/archives/<ARCHIVEID>/cfg/cfg.d/z_pda_handler.pl`.
4. Make any required modifications to `<EPRINTS_PATH>/archives/<ARCHIVEID>/cfg/cfg.d/z_pda_handler.pl`.  Typically, this would be to add fields to `$c->{pda}->{preserve_fields}` if you  do not want Pure to be able to overwrite these if it is updating an item in EPrints.
5. Reload the webserver.  (E.g. `apachectl graceful`).
