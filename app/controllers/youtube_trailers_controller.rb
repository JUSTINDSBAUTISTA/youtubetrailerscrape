require "csv"
require "open-uri"
require "zip"
require "pp"

class YoutubeTrailersController < ApplicationController
  LINKS_BEFORE_LOCATION_CHANGE = 15

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
      @youtube_data << youtube_data if youtube_data.present?

      # Update the main progress after each video is processed
      @@progress[:current] = index + 1

      # Simulate finer progress by incrementing in small steps
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

  # Method to retrieve scraping progress
  def progress
    Rails.logger.info "Progress: #{@@progress[:current]} / #{@@progress[:total]}"
    render json: {
      current: @@progress[:current] || 0,
      total: @@progress[:total] || 1 # Avoid division by zero
    }
  end

  private

  def change_vpn_location
    Rails.logger.info "Changing VPN location..."
    system("osascript #{Rails.root.join('location_handler.scpt')}")
    sleep(10) # Allow extra time for VPN to connect
  end

  def scrape_youtube_data(youtube_link, id_tag)
    # Define paths using id_tag from CSV
    thumbnail_path = @batch_folder.join("Thumbnail_Image", "#{id_tag}-Image.jpg")
    title_path = @batch_folder.join("Video_Title", "#{id_tag}-Title.txt")
    description_path = @batch_folder.join("Video_Description", "#{id_tag}-Description.txt")
    video_output_path = @batch_folder.join("Video", "#{id_tag}-Video.mp4")

    # Download and save video
    download_successful = download_youtube_video(youtube_link, video_output_path)

    # Save additional data only if download is successful
    if download_successful
      video_details = parse_youtube_html(fetch_youtube_html(youtube_link))
      return {} if video_details.blank?

      # Save the title, description, and thumbnail using id_tag from CSV
      File.write(title_path, video_details[:title])
      File.write(description_path, video_details[:description])
      download_image(video_details[:thumbnail], thumbnail_path)

      # Return video details to be appended to the list
      video_details.merge(video_path: video_output_path, idTag: id_tag)
    else
      Rails.logger.error "Failed to download video for #{youtube_link}"
      {}
    end
  end

  def download_youtube_video(youtube_link, video_output_path)
    Rails.logger.info "Attempting to download video for #{youtube_link}"

    # Construct the command for yt-dlp
    command = "yt-dlp --proxy \"\" -f mp4 -o '#{video_output_path}' '#{youtube_link}'"

    # Log the command for verification
    Rails.logger.info "Running command: #{command}"

    # Run the command and capture output
    output = `#{command}`
    Rails.logger.info "Command output: #{output}"

    # Check the download success by verifying if the file exists
    video_exists = File.exist?(video_output_path)
    Rails.logger.info "Download successful? #{video_exists}"

    video_exists
  end

  def parse_youtube_html(html)
    Rails.logger.info "Parsing YouTube HTML..."
    doc = Nokogiri::HTML(html)
    script_tag = doc.css("script").find { |s| s.text.include?("ytInitialPlayerResponse") }
    return unless script_tag

    json_text = script_tag.text.match(/ytInitialPlayerResponse\s*=\s*(\{.+?\});/)
    return unless json_text

    json_data = JSON.parse(json_text[1]) rescue nil
    return unless json_data && json_data["videoDetails"]

    video_details = json_data["videoDetails"]
    {
      title: video_details["title"],
      thumbnail: video_details["thumbnail"]["thumbnails"].last["url"],
      description: video_details["shortDescription"],
      video_id: video_details["videoId"]
    }
  end

  def fetch_youtube_html(youtube_link)
    Rails.logger.info "Fetching HTML for #{youtube_link}..."
    URI.open(youtube_link).read
  rescue OpenURI::HTTPError => e
    Rails.logger.error "Failed to fetch YouTube HTML: #{e.message}"
    nil
  end

  def download_image(image_url, save_path)
    File.open(save_path, "wb") do |file|
      file.write URI.open(image_url).read
    end
  rescue => e
    Rails.logger.error "Failed to download image #{image_url}: #{e.message}"
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
