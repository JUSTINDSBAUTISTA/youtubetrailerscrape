Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index, :show ] do
    collection do
      post :fetch_youtube_trailers
      get :download_zip
      get :progress # Add the progress route here if it's missing
    end
  end

  root "youtube_trailers#index"
end
