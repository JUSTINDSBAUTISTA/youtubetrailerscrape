Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index ] do
    collection do
      post :fetch
      post :retry_failed
      post :stop_scraping
      post :reset
      get :progress
    end
  end

  root "youtube_trailers#index"
end
