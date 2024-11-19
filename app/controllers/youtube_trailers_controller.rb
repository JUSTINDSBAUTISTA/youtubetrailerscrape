require "csv"
require "open-uri"
require "zip"
require "aws-sdk-s3"

class YoutubeTrailersController < ApplicationController
  @@progress = { current: 0, total: 0 }

  # Fetch and process CSV file
  def fetch
    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    today_date = Date.today.strftime("%Y-%m-%d")
    @@progress[:total] = 0
    @@progress[:current] = 0

    csv_data = CSV.read(file_path, headers: true)
    @@progress[:total] = csv_data.size

    if csv_data.headers == %w[idTag YoutubeLink]
      handle_new_csv(csv_data, today_date)
      redirect_to download_zip_youtube_trailers_path(zip_name: "#{today_date}-Batch/youtube_trailers_data.zip")
    else
      render json: { error: "Invalid CSV format. Please upload a valid file." }, status: :unprocessable_entity
      nil
    end
  end

  # Download ZIP file
  def download_zip
    zip_name = params[:zip_name]
    if zip_name.blank?
      render plain: "ZIP name is missing", status: :bad_request
      return
    end

    begin
      s3_object = s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(zip_name)
      unless s3_object.exists?
        render plain: "The requested ZIP file does not exist on S3.", status: :not_found
        return
      end

      zip_data = s3_object.get.body.read

      # Send the ZIP file as a response
      send_data zip_data,
                filename: File.basename(zip_name),
                type: "application/zip",
                disposition: "attachment"
    rescue Aws::S3::Errors::NoSuchKey
      render plain: "The requested ZIP file does not exist on S3.", status: :not_found
    rescue StandardError => e
      render plain: "Error fetching ZIP file: #{e.message}", status: :internal_server_error
    end
  end


  # Retry failed uploads
  def retry_failed
    file_path = Rails.root.join("tmp", "updated_links.csv")
    return redirect_to youtube_trailers_path, alert: "No previous CSV found." unless File.exist?(file_path)

    csv_data = CSV.read(file_path, headers: true)
    failed_rows = csv_data.select { |row| row["failure"] == "1" }

    if failed_rows.empty?
      redirect_to youtube_trailers_path, notice: "All links are successfully scraped."
      return
    end

    today_date = Date.today.strftime("%Y-%m-%d")
    handle_updated_csv(failed_rows, today_date)
    redirect_to youtube_trailers_path, notice: "Retry completed. Check the updated CSV."
  end

  # Display progress
  def progress
    render json: {
      current: @@progress[:current] || 0,
      total: @@progress[:total] || 1
    }
  end

  private

  # Handle a new CSV
  def handle_new_csv(csv_data, today_date)
    Tempfile.create([ "youtube_trailers", ".zip" ]) do |tempfile|
      Zip::OutputStream.open(tempfile) do |zip|
        csv_data.each_with_index do |row, index|
          youtube_link = row["YoutubeLink"]
          id_tag = row["idTag"]

          scrape_youtube_data(youtube_link, id_tag, zip, today_date)
          @@progress[:current] = index + 1
        end
      end

      tempfile.rewind
      upload_zip_to_s3(tempfile, today_date)
    end
  end

  # Scrape YouTube data and upload to S3
  def scrape_youtube_data(youtube_link, id_tag, zip, today_date)
    return false unless youtube_link =~ /\Ahttps:\/\/(www\.)?youtube\.com\/watch\?v=.+/

    begin
      fetch_youtube_data(youtube_link, "title", zip, "Video_Title/#{id_tag}-Title.txt", today_date)
      fetch_youtube_data(youtube_link, "description", zip, "Video_Description/#{id_tag}-Description.txt", today_date, true)
      fetch_youtube_data(youtube_link, "thumbnail", zip, "Thumbnail_Image/#{id_tag}-Image.jpg", today_date, true)
      fetch_youtube_video(youtube_link, zip, "Video/#{id_tag}-Video.mp4", today_date)
      true
    rescue StandardError => e
      Rails.logger.error("Error processing #{youtube_link}: #{e.message}")
      false
    end
  end

  def fetch_youtube_data(link, data_type, zip, s3_key, today_date, is_file = false)
    # Define explicit output filename
    output_file = Rails.root.join("tmp", "#{data_type}-#{SecureRandom.uuid}")

    # yt-dlp command with explicit output file
    command_map = {
      "title" => "--print 'title'",
      "description" => "--write-description --skip-download -o '#{output_file}.description'",
      "thumbnail" => "--write-thumbnail --skip-download -o '#{output_file}.%(ext)s'"
    }
    command = "yt-dlp --proxy '' #{command_map[data_type]} '#{link}'"

    if data_type == "title"
      # Capture title as string (not file)
      result = `#{command}`.strip
      return if result.empty?

      # Save title to local folder
      folder_name = Rails.root.join("tmp", File.dirname(s3_key)) # e.g., tmp/Video_Title/
      FileUtils.mkdir_p(folder_name) # Create folder if it doesn't exist

      local_file_path = folder_name.join(File.basename(s3_key)) # e.g., tmp/Video_Title/798762-Title.txt
      File.write(local_file_path, result) # Write the title to a text file

      # Read and upload to S3
      data = File.read(local_file_path)
      zip.put_next_entry(s3_key) # Add to ZIP archive
      zip.write(data)
      upload_to_s3("#{today_date}-Batch/#{s3_key}", local_file_path)

      File.delete(local_file_path) # Clean up local temp file
    elsif is_file
      # Run the command to fetch the file
      system(command)

      # Locate the downloaded file
      file_path = Dir.glob("#{output_file}*").find { |f| File.exist?(f) }
      unless file_path
        Rails.logger.error("File not found for #{data_type} at #{file_path}")
        return
      end

      # Move file to the correct local folder
      folder_name = Rails.root.join("tmp", File.dirname(s3_key)) # Create folder structure locally
      FileUtils.mkdir_p(folder_name) # Ensure folder exists

      local_file_path = folder_name.join(File.basename(s3_key)) # Move to e.g., tmp/Video_Description/798762-Description.txt
      FileUtils.mv(file_path, local_file_path)

      # Read and upload to S3
      data = File.read(local_file_path)
      zip.put_next_entry(s3_key) # Add to ZIP archive
      zip.write(data)
      upload_to_s3("#{today_date}-Batch/#{s3_key}", local_file_path)

      File.delete(local_file_path) # Clean up local temp file
    else
      # Run command and capture output
      result = `#{command}`.strip
      return if result.empty?

      zip.put_next_entry(s3_key) # Add to ZIP archive
      zip.write(result)
      upload_to_s3("#{today_date}-Batch/#{s3_key}", result) # Upload to S3
    end
  rescue StandardError => e
    Rails.logger.error("Error processing #{data_type} for #{link}: #{e.message}")
  end

  # Fetch and upload YouTube video
  def fetch_youtube_video(link, zip, s3_key, today_date)
    folder_name = File.dirname(s3_key)
    local_temp_path = Rails.root.join("tmp", folder_name)
    FileUtils.mkdir_p(local_temp_path)

    temp_video_path = local_temp_path.join(File.basename(s3_key))
    video_command = "yt-dlp --proxy '' -f 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]' -o '#{temp_video_path}' '#{link}'"
    system(video_command)

    return unless File.exist?(temp_video_path)

    data = File.read(temp_video_path)
    zip.put_next_entry(s3_key)
    zip.write(data)
    upload_to_s3("#{today_date}-Batch/#{s3_key}", temp_video_path)

    File.delete(temp_video_path)
  end

  # Upload ZIP to S3
  def upload_zip_to_s3(zip_file, today_date)
    zip_key = "#{today_date}-Batch/youtube_trailers_data.zip"
    s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(zip_key).put(body: zip_file.read)
    Rails.logger.info("ZIP file uploaded to S3: #{zip_key}")
  end

  # Upload data to S3
  def upload_to_s3(key, file_path)
    obj = s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(key)
    obj.upload_file(file_path.to_s)
    Rails.logger.info("Uploaded to S3: #{key}")
  end

  # S3 Client Configuration
  def s3_client
    @s3_client ||= Aws::S3::Resource.new(
      region: ENV["AWS_REGION"],
      credentials: Aws::Credentials.new(
        ENV["AWS_ACCESS_KEY_ID"],
        ENV["AWS_SECRET_ACCESS_KEY"]
      )
    )
  end
end
