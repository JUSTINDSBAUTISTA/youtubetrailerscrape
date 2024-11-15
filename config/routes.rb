Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index, :show ] do
    collection do
      post :fetch
      post :retry_failed
      get :progress
      get :download_zip # Ensure this route is included for ZIP downloads
    end
  end

  root "youtube_trailers#index"
end
