Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index ] do
    collection do
      post :fetch
      post :retry_failed
      get :progress
      get :download_zip
      post :pause_scraping
      post :resume_scraping
      post :stop_scraping
    end
  end

  root "youtube_trailers#index"
end
