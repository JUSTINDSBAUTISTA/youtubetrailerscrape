require "test_helper"

class YoutubeTrailersControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get youtube_trailers_index_url
    assert_response :success
  end
end
