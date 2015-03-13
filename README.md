About AutoTest
===============

This AutoTest System is designed to undertake the building and testing process
automatically. It depends on the following packages:

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

Online Registration
===================

The system adopts a ticket-based authentication mechanism for registration. You
should first specify who can register new repos and how many repos each user can
register at most, according to the format in ticket_mgmt/tickets.quota.template.

    git-autotester$ cd ticket_mgmt
	ticket_mgmt$ cp tickets.quota.template tickets.quota
	(edit tickets.quota according to your setting)
	ticket_mgmt$ ./ticket init

Users are identified by their email addresses.

To enable the online registration page (i.e. /register), set :enable: in the
:registration: section to true and restart the frontend (the backend should
reload the config file automatically).

To successfully register a repo, the user must provide his email address and url
of the repo, and ensure that the following conditions are met.

* the email address provided is listed in tickets.quota,
* the email address has not used up its quota,
* the url given is a valid git repo, i.e. we can clone the repo without keys,
* the email address in the Author field of the HEAD commit is the same as the
  one given, and
* the repo has not been registered before.

A notification about the result of the registration request will be sent to the
email address once the request has been processed. Once successfully registered,
the repo will be periodically fetched and tested. If the user checks the
'public' box in the registration request, the repo will also be listed on the
index page.

Marking
=======

The AutoTest system can send scores on request. To enable this feature, you
should first provide the following information.

* :authorized_users: a list of users with their user id, name, student id, email
  address and repo url,
* :grade: a script which calculates the score from a set of testing reports, and
* :respond_cmd: a ruby script which sends the response.


Setting :enable: in the :marking: section will enable this feature. To request
for a score, one should post to "/mooc_marking" with the user id and lab to be
marked.
