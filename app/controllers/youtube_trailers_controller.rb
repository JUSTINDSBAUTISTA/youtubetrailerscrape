require "csv"
require "open-uri"
require "zip"
require "pp"

class YoutubeTrailersController < ApplicationController
  LINKS_BEFORE_LOCATION_CHANGE = 10

  @@progress = { current: 0, total: 0 }

  # Initialize progress for scraping
  def fetch_youtube_trailers
    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    @youtube_data = []
    today_date = Date.today.strftime("%Y-%m-%d")
    @batch_folder = Rails.root.join("public", "#{today_date}-Batch")

    # Create main batch folder and subdirectories
    %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
      FileUtils.mkdir_p(@batch_folder.join(subfolder))
    end

    csv_data = CSV.read(file_path, headers: true)
    @@progress[:total] = csv_data.size
    @@progress[:current] = 0

    csv_data.each_with_index do |row, index|
      youtube_link = row["YoutubeLink"]
      id_tag = row["idTag"]

      # Change VPN location every LINKS_BEFORE_LOCATION_CHANGE downloads
      change_vpn_location if (index % LINKS_BEFORE_LOCATION_CHANGE).zero? && index != 0

      youtube_data = scrape_youtube_data(youtube_link, id_tag)
      if youtube_data.present?
        # Read contents of title and description files
        youtube_data[:title_content] = File.read(youtube_data[:title]) if File.exist?(youtube_data[:title])
        youtube_data[:description_content] = File.read(youtube_data[:description]) if File.exist?(youtube_data[:description])

        # Convert file paths to URLs relative to the `public` folder
        youtube_data[:thumbnail_url] = "/#{today_date}-Batch/Thumbnail_Image/#{id_tag}-Image.jpg"
        youtube_data[:video_url] = "/#{today_date}-Batch/Video/#{id_tag}-Video.mp4"

        # Add the data to the array for JSON output
        @youtube_data << youtube_data.slice(:title_content, :description_content, :thumbnail_url, :video_url, :idTag)
      end

      # Update the main progress after each video is processed
      @@progress[:current] = index + 1
      (1..5).each do |i|
        @@progress[:current] = index + (i * 0.2)
        sleep(0.1) # Short delay to simulate gradual progress in the front end
      end
    end

    # Save data to JSON for display on the index page
    json_file_path = @batch_folder.join("youtube_data.json")
    File.write(json_file_path, @youtube_data.to_json)

    # Generate ZIP file if data exists
    if @youtube_data.any?
      zip_file_path = generate_zip_file(@youtube_data, today_date)
      send_file zip_file_path, type: "application/zip", disposition: "attachment", filename: "#{today_date}_youtube_trailers_data.zip"
    else
      redirect_to youtube_trailers_path, alert: "No data was available to scrape."
    end
  end


  def progress
    Rails.logger.info "Progress: #{@@progress[:current]} / #{@@progress[:total]}"
    render json: {
      current: @@progress[:current] || 0,
      total: @@progress[:total] || 1 # Avoid division by zero
    }
  end

  private

  def scrape_youtube_data(youtube_link, id_tag)
    title_path = @batch_folder.join("Video_Title", "#{id_tag}-Title.txt")
    description_path = @batch_folder.join("Video_Description", "#{id_tag}-Description.txt")
    thumbnail_path = @batch_folder.join("Thumbnail_Image", "#{id_tag}-Image.jpg")
    video_output_path = @batch_folder.join("Video", "#{id_tag}-Video.mp4")

    # Download title
    title = `yt-dlp --proxy "" --print "title" --skip-download "#{youtube_link}"`.strip
    File.write(title_path, title)

    # Download description
    description_command = "yt-dlp --proxy \"\" --write-description --skip-download -o \"#{description_path}\" \"#{youtube_link}\""
    system(description_command)
    File.rename("#{description_path}.description", description_path) if File.exist?("#{description_path}.description")

    # Download thumbnail (forcing to .jpg format)
    thumbnail_command = "yt-dlp --proxy \"\" --write-thumbnail --skip-download -o \"#{thumbnail_path}\" \"#{youtube_link}\""
    system(thumbnail_command)
    downloaded_thumbnail_path = Dir.glob("#{thumbnail_path}*").find { |f| f =~ /\.jpg|\.webp$/ }
    File.rename(downloaded_thumbnail_path, thumbnail_path) if downloaded_thumbnail_path && downloaded_thumbnail_path != thumbnail_path

    # Download video
    video_command = "yt-dlp --proxy \"\" -f mp4 -o \"#{video_output_path}\" \"#{youtube_link}\""
    system(video_command)

    # Return metadata
    {
      title: title_path,
      description: description_path,
      thumbnail: thumbnail_path,
      video: video_output_path,
      idTag: id_tag
    }
  end

  def change_vpn_location
    Rails.logger.info "Changing VPN location..."
    system("osascript #{Rails.root.join('location_handler.scpt')}")
    sleep(10) # Allow extra time for VPN to connect
  end

  def generate_zip_file(youtube_data, date)
    zip_file_path = Rails.root.join("public", "#{date}_youtube_trailers_data.zip")

    # Remove old zip file if it exists
    File.delete(zip_file_path) if File.exist?(zip_file_path)

    # Create a zip file
    Zip::File.open(zip_file_path, Zip::File::CREATE) do |zipfile|
      %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
        subfolder_path = @batch_folder.join(subfolder)
        Dir.glob("#{subfolder_path}/*").each do |file|
          zipfile.add("#{subfolder}/#{File.basename(file)}", file)
          Rails.logger.info "Added #{file} to ZIP."
        end
      end
    end

    Rails.logger.info "ZIP file created at #{zip_file_path}"
    zip_file_path
  end
end
