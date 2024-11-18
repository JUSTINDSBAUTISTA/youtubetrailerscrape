require "csv"
require "open-uri"
require "zip"
require "pp"
require "aws-sdk-s3"

class YoutubeTrailersController < ApplicationController
  LINKS_BEFORE_LOCATION_CHANGE = 10

  @@progress = { current: 0, total: 0 }

  def fetch
    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    today_date = Date.today.strftime("%Y-%m-%d")
    @batch_folder = Rails.root.join("public", "#{today_date}-Batch")

    %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
      FileUtils.mkdir_p(@batch_folder.join(subfolder))
    end

    csv_data = CSV.read(file_path, headers: true)
    @@progress[:total] = csv_data.size
    @@progress[:current] = 0

    if csv_data.headers == %w[idTag YoutubeLink]
      handle_new_csv(csv_data)
    elsif csv_data.headers == %w[idTag YoutubeLink success failure]
      handle_updated_csv(csv_data)
    else
      render json: { error: "Invalid CSV format. Please upload a valid file." }, status: :unprocessable_entity
      return
    end

    upload_to_s3(today_date)
    generate_zip_file(today_date)
  end

  def handle_new_csv(csv_data)
    today_date = Date.today.strftime("%Y-%m-%d") # Ensure today_date is defined
    batch_path = Rails.root.join("public", "#{today_date}-Batch")
    updated_csv_path = Rails.root.join("public", "updated_links.csv") # Default path
    batch_csv_path = batch_path.join("updated_links.csv") # New path inside batch folder

    youtube_data = []

    [ updated_csv_path, batch_csv_path ].each do |path|
      CSV.open(path, "wb") do |csv| # Open each file for writing
        csv << %w[idTag YoutubeLink success failure] # Add headers to the CSV file

        csv_data.each_with_index do |row, index| # Iterate through the rows in the input CSV
          youtube_link = row["YoutubeLink"]
          id_tag = row["idTag"]

          change_vpn_location if (index % LINKS_BEFORE_LOCATION_CHANGE).zero? && index != 0
          success = scrape_youtube_data(youtube_link, id_tag)

          youtube_data << { idTag: id_tag, YoutubeLink: youtube_link, success: success ? 1 : 0, failure: success ? 0 : 1 }
          csv << [ id_tag, youtube_link, success ? 1 : 0, success ? 0 : 1 ] # Write each row to both files
          @@progress[:current] = index + 1
        end
      end
    end

    youtube_data_path = batch_path.join("youtube_data.json")
    File.write(youtube_data_path, youtube_data.to_json) # Write JSON data to a file
  end

  def handle_updated_csv(csv_data)
    today_date = Date.today.strftime("%Y-%m-%d") # Ensure today_date is defined
    batch_path = Rails.root.join("public", "#{today_date}-Batch")
    updated_csv_path = Rails.root.join("public", "updated_links.csv") # Default path
    batch_csv_path = batch_path.join("updated_links.csv") # New path inside batch folder

    failed_rows = csv_data.select { |row| row["failure"] == "1" }

    if failed_rows.empty?
      redirect_to youtube_trailers_path, notice: "All links are successfully scraped."
      return
    end

    youtube_data = []

    [ updated_csv_path, batch_csv_path ].each do |path|
      CSV.open(path, "wb") do |csv| # Open each file for writing
        csv << %w[idTag YoutubeLink success failure] # Add headers to the CSV file

        failed_rows.each_with_index do |row, index| # Iterate through the failed rows
          youtube_link = row["YoutubeLink"]
          id_tag = row["idTag"]

          change_vpn_location if (index % LINKS_BEFORE_LOCATION_CHANGE).zero? && index != 0
          success = scrape_youtube_data(youtube_link, id_tag)

          youtube_data << { idTag: id_tag, YoutubeLink: youtube_link, success: success ? 1 : 0, failure: success ? 0 : 1 }
          csv << [ id_tag, youtube_link, success ? 1 : 0, success ? 0 : 1 ] # Write each row to both files
          @@progress[:current] = index + 1
        end
      end
    end

    youtube_data_path = batch_path.join("youtube_data.json")
    File.write(youtube_data_path, youtube_data.to_json) # Write JSON data to a file
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
      csv << %w[idTag YoutubeLink success failure]

      failed_rows.each_with_index do |row, index|
        youtube_link = row["YoutubeLink"]
        id_tag = row["idTag"]

        success = scrape_youtube_data(youtube_link, id_tag)

        youtube_data << { idTag: id_tag, YoutubeLink: youtube_link, success: success ? 1 : 0, failure: success ? 0 : 1 }
        csv << [ id_tag, youtube_link, success ? 1 : 0, success ? 0 : 1 ]
      end
    end

    youtube_data_path = @batch_folder.join("youtube_data.json")
    File.write(youtube_data_path, youtube_data.to_json)
    redirect_to youtube_trailers_path, notice: "Retry completed. Check the updated CSV."
  end

  def progress
    render json: {
      current: @@progress[:current] || 0,
      total: @@progress[:total] || 1
    }
  end

  private

  def scrape_youtube_data(youtube_link, id_tag)
    return false unless youtube_link =~ /\Ahttps:\/\/(www\.)?youtube\.com\/watch\?v=.+/

    title_path = @batch_folder.join("Video_Title", "#{id_tag}-Title.txt")
    description_path = @batch_folder.join("Video_Description", "#{id_tag}-Description.txt")
    thumbnail_path = @batch_folder.join("Thumbnail_Image", "#{id_tag}-Image.jpg")
    video_output_path = @batch_folder.join("Video", "#{id_tag}-Video.mp4")

    begin
      # Fetch title
      title = `yt-dlp --proxy "" --print "title" --skip-download "#{youtube_link}"`.strip
      unless title.empty?
        File.write(title_path, title)
      else
        Rails.logger.error("Failed to retrieve title for: #{youtube_link}")
        return false
      end

      # Fetch description
      description_command = "yt-dlp --proxy \"\" --write-description --skip-download -o \"#{description_path}\" \"#{youtube_link}\""
      system(description_command)
      description_file = "#{description_path}.description"
      if File.exist?(description_file)
        File.rename(description_file, description_path)
      else
        Rails.logger.error("Failed to retrieve description for: #{youtube_link}")
      end

      # Fetch thumbnail
      thumbnail_command = "yt-dlp --proxy \"\" --write-thumbnail --skip-download -o \"#{thumbnail_path}\" \"#{youtube_link}\""
      system(thumbnail_command)
      downloaded_thumbnail_path = Dir.glob("#{thumbnail_path}*").find { |f| f =~ /\.(jpg|webp)$/ }
      if downloaded_thumbnail_path
        File.rename(downloaded_thumbnail_path, thumbnail_path)
      else
        Rails.logger.error("Failed to retrieve thumbnail for: #{youtube_link}")
      end

      # Fetch video
      video_command = "yt-dlp --proxy \"\" -f \"bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]\" -o \"#{video_output_path}\" \"#{youtube_link}\""
      system(video_command)
      unless File.exist?(video_output_path)
        Rails.logger.error("Failed to retrieve video for: #{youtube_link}")
      end

      true
    rescue StandardError => e
      Rails.logger.error("Error processing #{youtube_link}: #{e.message}")
      false
    end
  end


  def change_vpn_location
    system("osascript #{Rails.root.join('location_handler.scpt')}")
    sleep(10)
  end

  def upload_to_s3(today_date)
    s3 = Aws::S3::Resource.new(
      region: ENV["AWS_REGION"],
      credentials: Aws::Credentials.new(
        ENV["AWS_ACCESS_KEY_ID"],
        ENV["AWS_SECRET_ACCESS_KEY"]
      )
    )
    bucket = s3.bucket(ENV["AWS_BUCKET_NAME"])

    main_folder = "#{today_date}-Batch"

    %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
      subfolder_path = @batch_folder.join(subfolder)
      Dir.glob("#{subfolder_path}/*").each do |file|
        s3_key = "#{main_folder}/#{subfolder}/#{File.basename(file)}"
        obj = bucket.object(s3_key)

        # Upload file without ACL (public-read should be handled by bucket policy)
        obj.upload_file(file)
        obj
      end
    end
  rescue Aws::S3::Errors::AccessDenied => e
    Rails.logger.error("Access Denied: Ensure the bucket policy allows uploads: #{e.message}")
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("Failed to upload to S3: #{e.message}")
  end

  def download_zip
    today_date = Date.today.strftime("%Y-%m-%d")
    zip_file_path = Rails.root.join("public", "#{today_date}_youtube_trailers_data.zip")

    if File.exist?(zip_file_path)
      send_file zip_file_path, type: "application/zip", disposition: "attachment", filename: "#{today_date}_youtube_trailers_data.zip"
    else
      render json: { error: "ZIP file not found." }, status: :not_found
    end
  end

  def generate_zip_file(date)
    zip_file_path = Rails.root.join("public", "#{date}_youtube_trailers_data.zip")
    File.delete(zip_file_path) if File.exist?(zip_file_path)

    Zip::File.open(zip_file_path, Zip::File::CREATE) do |zipfile|
      %w[Thumbnail_Image Video_Title Video_Description Video].each do |subfolder|
        subfolder_path = @batch_folder.join(subfolder)
        Dir.glob("#{subfolder_path}/*").each { |file| zipfile.add("#{subfolder}/#{File.basename(file)}", file) }
      end
    end

    zip_file_path
  end
end
