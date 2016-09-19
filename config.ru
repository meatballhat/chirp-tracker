#!/usr/bin/env rackup
# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))
require 'chirp_tracker'
run ChirpTracker
