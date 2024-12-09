Rails.application.routes.draw do
  resources :youtube_trailers, only: [:index, :show] do
    collection do
      post :fetch
      post :retry_failed
      post :stop_scraping
      post :reset
      post :update_yt_dlp
      get :progress
    end
  end

  root "youtube_trailers#index"
end
