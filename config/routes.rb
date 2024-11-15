Rails.application.routes.draw do
  resources :youtube_trailers, only: [ :index, :show ] do
    collection do
      post :fetch
      get :download_zip
      get :progress
    end
  end

  root "youtube_trailers#index"
end
