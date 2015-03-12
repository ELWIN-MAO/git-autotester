#!/usr/bin/env ruby
# encoding: utf-8

require 'net/http'

def respond(id, lab, score)
    uri = URI('http://localhost:14567/about')
    res = Net::HTTP.post_form(uri, 'id' => id, 'lab' => lab, 'score' => score)
end

##
# Local variables:
# ruby-indent-level: 4
# End:
##
