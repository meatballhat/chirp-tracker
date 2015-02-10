#!/usr/bin/env rackup
$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))
require 'chirp_tracker'
run ChirpTracker
