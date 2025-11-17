"jschol-tools" - eScholarship-related tools on submit servers
===========================

Description of files
--------------------

* `Gemfile`: Lists of Ruby gems the app uses. Used by 'bundler' to download and install them locally.
* `Gemfile.lock`: Copy of Gemfile created and managed by 'bundler'. Don't modify directly.
* `README.md`: This file.
* `LICENSE`: Software license.
* `config/`: A place to keep environment variables such as database and S3 connection parameters.
* `setup.sh`: Sequence of commands to run bundler to download and install all the Ruby modules the tools need.
* `bin/`: Gets populated by 'bundler' with driver scripts for gems it installs. Don't modify directly.
* `gems/`: Gets populated by 'bundler' with driver scripts for gems it installs. Don't modify directly.
* `migrations/`: Database schema in Ruby form. We can add new files here to morph the schema over time, and people can automatically upgrade their db.
* `once_only/`: Scripts created for a specific purpose and not ongoing use. (Includes instructions and script to sync prd data to stg/dev but unclear if it is up to date)
* `tools/`: Conversion and database maintenance tools.
* `tools/convert.rb`: Script to populate the new eschol5 database with units, item, etc. from the old eScholarship.
* `normalized/`: temp storage used by convert (can be used for debugging)
* `splash/`: script to create splash pages and script to set up requirements for same
* `tocExtract/`: used by convert.rb to extract the table of contents from pdfs
* `util/`: additional code used by convert.rb
* Stats and emails
- * `SENDING_STATS`: instructions for how to send stats
- * `lib/COUNTER-Robots`: used by stats to exclude robots
- * `mailTemplates`: Templates used by `massEmail.sh` to format email text 
- * `massEmail.sh`: wrapper script to run massEmails.rb


Migrating to a new database version
-----------------------------------

* `tools/migrate.rb`
