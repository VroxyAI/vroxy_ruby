# frozen_string_literal: true

class PagesController < ApplicationController
  def home; end

  def billing
    render :home
  end
end
