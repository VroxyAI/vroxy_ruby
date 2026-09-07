# frozen_string_literal: true

Rails.application.routes.draw do
  root "pages#home"
  get "/billing", to: "pages#billing"
  get "/up",      to: proc { [ 200, { "content-type" => "text/html" }, [ "<html><body>ok</body></html>" ] ] }
end
