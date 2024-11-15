require "csv"
require "open-uri"
require "zip"
require "pp"

class YoutubeTrailersController < ApplicationController
  LINKS_BEFORE_LOCATION_CHANGE = 10

  @@progress = { current: 0, total: 0 }

  def fetch
    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    today_date = Date.today.strftime("%Y-%m-%d")
    @batch_folder = Rails.root.join("public", "#{today_date}-Batch")

    # Create main batch folder and subdirectories
    %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
      FileUtils.mkdir_p(@batch_folder.join(subfolder))
    end

    csv_data = CSV.read(file_path, headers: true)
    @@progress[:total] = csv_data.size
    @@progress[:current] = 0

    # Prepare updated CSV file and youtube_data.json
    updated_csv_path = Rails.root.join("public", "updated_links.csv")
    youtube_data = []

    CSV.open(updated_csv_path, "wb") do |csv|
      csv << %w[idTag YoutubeLink success failure] # Write headers

      csv_data.each_with_index do |row, index|
        youtube_link = row["YoutubeLink"]
        id_tag = row["idTag"]

        change_vpn_location if (index % LINKS_BEFORE_LOCATION_CHANGE).zero? && index != 0

        success = scrape_youtube_data(youtube_link, id_tag)

        youtube_data << {
          idTag: id_tag,
          YoutubeLink: youtube_link,
          success: success ? 1 : 0,
          failure: success ? 0 : 1
        }

        csv << [ id_tag, youtube_link, success ? 1 : 0, success ? 0 : 1 ]
        @@progress[:current] = index + 1
      end
    end

    # Write youtube_data.json file inside the batch folder
    youtube_data_path = @batch_folder.join("youtube_data.json")
    File.write(youtube_data_path, youtube_data.to_json)

    # Generate ZIP file
    if Dir.exist?(@batch_folder)
      zip_file_path = generate_zip_file(today_date)
      send_file zip_file_path, type: "application/zip", disposition: "attachment", filename: "#{today_date}_youtube_trailers_data.zip"
    else
      redirect_to youtube_trailers_path, alert: "No data was available to scrape."
    end
  end

  def retry_failed
    file_path = Rails.root.join("public", "updated_links.csv")
    return redirect_to youtube_trailers_path, alert: "No previous CSV found." unless File.exist?(file_path)

    csv_data = CSV.read(file_path, headers: true)
    failed_rows = csv_data.select { |row| row["failure"] == "1" }

    if failed_rows.empty?
      redirect_to youtube_trailers_path, notice: "All links are successfully scraped."
      return
    end

    today_date = Date.today.strftime("%Y-%m-%d")
    @batch_folder = Rails.root.join("public", "#{today_date}-Retry-Batch")
    %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
      FileUtils.mkdir_p(@batch_folder.join(subfolder))
    end

    youtube_data = []

    CSV.open(file_path, "wb") do |csv|
      csv << %w[idTag YoutubeLink success failure] # Write headers again

      failed_rows.each_with_index do |row, index|
        youtube_link = row["YoutubeLink"]
        id_tag = row["idTag"]

        success = scrape_youtube_data(youtube_link, id_tag)

        youtube_data << {
          idTag: id_tag,
          YoutubeLink: youtube_link,
          success: success ? 1 : 0,
          failure: success ? 0 : 1
        }

        csv << [ id_tag, youtube_link, success ? 1 : 0, success ? 0 : 1 ]
      end
    end

    # Write youtube_data.json file inside the retry batch folder
    youtube_data_path = @batch_folder.join("youtube_data.json")
    File.write(youtube_data_path, youtube_data.to_json)

    redirect_to youtube_trailers_path, notice: "Retry completed. Check the updated CSV."
  end

  def progress
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

    begin
      title = `yt-dlp --proxy "" --print "title" --skip-download "#{youtube_link}"`.strip
      File.write(title_path, title)

      description_command = "yt-dlp --proxy \"\" --write-description --skip-download -o \"#{description_path}\" \"#{youtube_link}\""
      system(description_command)
      File.rename("#{description_path}.description", description_path) if File.exist?("#{description_path}.description")

      thumbnail_command = "yt-dlp --proxy \"\" --write-thumbnail --skip-download -o \"#{thumbnail_path}\" \"#{youtube_link}\""
      system(thumbnail_command)
      downloaded_thumbnail_path = Dir.glob("#{thumbnail_path}*").find { |f| f =~ /\.jpg|\.webp$/ }
      File.rename(downloaded_thumbnail_path, thumbnail_path) if downloaded_thumbnail_path && downloaded_thumbnail_path != thumbnail_path

      video_command = "yt-dlp --proxy \"\" -f \"bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]\" -o \"#{video_output_path}\" \"#{youtube_link}\""
      system(video_command)

      true # Success
    rescue StandardError => e
      Rails.logger.error("Failed to scrape #{youtube_link}: #{e.message}")
      false # Failure
    end
  end

  def change_vpn_location
    system("osascript #{Rails.root.join('location_handler.scpt')}")
    sleep(10)
  end

  def generate_zip_file(date)
    zip_file_path = Rails.root.join("public", "#{date}_youtube_trailers_data.zip")
    File.delete(zip_file_path) if File.exist?(zip_file_path)

    Zip::File.open(zip_file_path, Zip::File::CREATE) do |zipfile|
      %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
        subfolder_path = @batch_folder.join(subfolder)
        Dir.glob("#{subfolder_path}/*").each do |file|
          zipfile.add("#{subfolder}/#{File.basename(file)}", file)
        end
      end
    end

    zip_file_path
  end
end
