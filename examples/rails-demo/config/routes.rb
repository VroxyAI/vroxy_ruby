# frozen_string_literal: true

Rails.application.routes.draw do
  root "pages#home"
  get "/billing", to: "pages#billing"
  # Deliberate unhandled 500, ungated: the point is to confirm the gem
  # reports it, and a login wall in the way makes that harder to check.
  get "/boom",    to: "pages#boom"
  get "/up",      to: proc { [ 200, { "content-type" => "text/html" }, [ "<html><body>ok</body></html>" ] ] }
end
