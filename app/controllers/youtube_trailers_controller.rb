require "csv"
require "open-uri"
require "zip"
require "pp"

class YoutubeTrailersController < ApplicationController
  LINKS_BEFORE_LOCATION_CHANGE = 15 # Change location every 15 downloads

  def index
    json_file_path = Rails.root.join("public", "scraped_data", "youtube_data.json")
    @youtube_data = File.exist?(json_file_path) ? JSON.parse(File.read(json_file_path)) : []
  end

  def fetch_youtube_trailers
    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    @youtube_data = []
    today_date = Date.today.strftime("%Y-%m-%d")

    # Process each row in the CSV
    CSV.foreach(file_path, headers: true).with_index do |row, index|
      youtube_link = row["YoutubeLink"]
      id_tag = row["idTag"]
      Rails.logger.info "Processing YouTube link: #{youtube_link} with ID tag: #{id_tag}"

      # Change VPN location every LINKS_BEFORE_LOCATION_CHANGE downloads
      change_vpn_location if (index % LINKS_BEFORE_LOCATION_CHANGE).zero? && index != 0

      youtube_data = scrape_youtube_data(youtube_link, id_tag)
      @youtube_data << youtube_data if youtube_data.present?
    end

    # Save data to a JSON file instead of flash
    json_file_path = Rails.root.join("public", "scraped_data", "youtube_data.json")
    File.write(json_file_path, @youtube_data.to_json)

    # Generate ZIP file if there is data
    if @youtube_data.any?
      puts "Here..."
      @youtube_data.each_with_index do |data, index|
        puts "\nVideo ##{index + 1}"
        puts "Title: #{data[:title]}"
        puts "Thumbnail: #{data[:thumbnail]}"
        puts "Description: #{data[:description].truncate(100)}" # Shorten long descriptions
        puts "Video ID: #{data[:video_id]}"
        puts "-" * 50
      end

      zip_file_path = generate_zip_file(@youtube_data, today_date)
      send_file zip_file_path, type: "application/zip", disposition: "attachment", filename: "#{today_date}_youtube_trailers_data.zip"
    else
      redirect_to youtube_trailers_path, alert: "No data was available to scrape."
    end
  end


  private

  def change_vpn_location
    Rails.logger.info "Changing VPN location..."
    system("osascript #{Rails.root.join('location_handler.scpt')}")
    sleep(10) # Allow extra time for VPN to connect
  end

  def scrape_youtube_data(youtube_link, id_tag)
    html = fetch_youtube_html(youtube_link)
    return {} if html.nil?

    video_details = parse_youtube_html(html)
    if video_details.blank?
      Rails.logger.error "Failed to parse YouTube HTML for #{youtube_link}"
      return {}
    end

    save_scraped_data(video_details, id_tag)

    # Attempt video download; log if unsuccessful
    unless download_youtube_video(youtube_link, id_tag)
      Rails.logger.error "Failed to download video for #{youtube_link}"
    end

    video_details
  end

  def download_youtube_video(youtube_link, id_tag)
    Rails.logger.info "Attempting to download video for #{youtube_link}"

    # Ensure the output directory exists
    output_dir = Rails.root.join("public", "videos")
    FileUtils.mkdir_p(output_dir)

    # Define the output path for the video
    output_path = output_dir.join("#{id_tag}-video.mp4")

    # Use yt-dlp with additional flags to avoid proxy settings
    # Explicitly disable proxy with `--no-proxy` option
    command = "yt-dlp --no-proxy -f mp4 -o '#{output_path}' '#{youtube_link}'"
    system(command)

    # Verify the downloaded file
    video_exists = File.exist?(output_path)
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

  def save_scraped_data(video_details, id_tag)
    folder_path = Rails.root.join("public", "scraped_data", id_tag)
    FileUtils.mkdir_p(folder_path)

    # Save thumbnail image
    Rails.logger.info "Saving thumbnail for #{id_tag}..."
    download_image(video_details[:thumbnail], folder_path.join("#{id_tag}-image.jpg"))

    # Save title
    Rails.logger.info "Saving title for #{id_tag}..."
    File.write(folder_path.join("#{id_tag}-Title.txt"), video_details[:title])

    # Save description
    Rails.logger.info "Saving description for #{id_tag}..."
    File.write(folder_path.join("#{id_tag}-Description.txt"), video_details[:description])
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
      youtube_data.each do |data|
        id_tag = data[:idTag]
        next if id_tag.nil?

        folder_path = Rails.root.join("public", "scraped_data", id_tag)

        zipfile.add("#{id_tag}/#{id_tag}-image.jpg", folder_path.join("#{id_tag}-image.jpg")) if File.exist?(folder_path.join("#{id_tag}-image.jpg"))
        zipfile.add("#{id_tag}/#{id_tag}-Title.txt", folder_path.join("#{id_tag}-Title.txt")) if File.exist?(folder_path.join("#{id_tag}-Title.txt"))
        zipfile.add("#{id_tag}/#{id_tag}-Description.txt", folder_path.join("#{id_tag}-Description.txt")) if File.exist?(folder_path.join("#{id_tag}-Description.txt"))
        zipfile.add("#{id_tag}/#{id_tag}-video.mp4", Rails.root.join("public", "videos", "#{id_tag}-video.mp4")) if File.exist?(Rails.root.join("public", "videos", "#{id_tag}-video.mp4"))
      end
    end
    Rails.logger.info "ZIP file created at #{zip_file_path}"

    zip_file_path # Return the path for further use
  end
end
