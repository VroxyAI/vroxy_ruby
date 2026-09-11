# frozen_string_literal: true

class PagesController < ApplicationController
  def home; end

  def billing
    render :home
  end

  class DemoBoom < StandardError; end

  def boom
    raise DemoBoom, "Deliberate 500 from the vroxy rails-demo at #{Time.now.utc.iso8601} — " \
                    "this should appear in your vroxy workspace under Errors."
  end
end
