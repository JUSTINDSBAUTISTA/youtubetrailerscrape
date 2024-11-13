Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index, :show ] do
    collection do
      post :fetch_youtube_trailers
      get :download_zip # Route to download the ZIP file if needed
    end
  end

  # Set the root path to the index of youtube_trailers
  root "youtube_trailers#index"
end
