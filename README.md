About Autobuild
===============

This Autobuild System is designed to undertake the building and testing
process automatically. It depends on the following packages:

+ Git
+ Bash
+ Exim4 (for mailing)
+ Ruby 1.9.3 or newer, with bundle
+ All dependencies required by repos under testing

Deployment
==========

Install required ruby gems first:

    git-autotester$ bundle install

Then create the configuration file based on the template:

    git-autotester$ cp config.yaml.template config.yaml

After Updating the fields named repo\_abspath, result\_abspath and repos, start
the service:

    git-autotester$ ruby frontend.rb & > frontend.log 2>&1
    git-autotester$ ruby backend.rb & > backend.log 2>&1

It is recommended to start the frontend/backend in tmux so that they will not be
killed when you log out.
