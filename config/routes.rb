Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index ] do
    collection do
      post :fetch
      post :retry_failed
      get :progress
      get :download_zip
    end
  end

  root "youtube_trailers#index"
end
