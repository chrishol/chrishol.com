require 'httparty'
require 'octokit'
require 'json'
require 'base64'
require 'dotenv'

# Load the .env file relative to the script's location
Dotenv.load(File.expand_path('../../.env', __FILE__))

SPOTIFY_TOKEN_URL = 'https://accounts.spotify.com/api/token'
SPOTIFY_SEARCH_URL = 'https://api.spotify.com/v1/search'
LAST_FM_BASE_URL = 'https://ws.audioscrobbler.com/2.0'
MUSIC_BRAINZ_BASE_URL = 'https://musicbrainz.org/ws/2'

# Fetch top tracks from Last.fm
def fetch_top_tracks
  url = "#{LAST_FM_BASE_URL}/?method=user.gettoptracks&user=#{ENV['USERNAME']}&period=1month&limit=10&api_key=#{ENV['LAST_FM_API_KEY']}&format=json"
  response = HTTParty.get(url)
  return response.parsed_response['toptracks']['track'] if response.code == 200

  puts "Error fetching data from Last.fm: #{response.body}"
  []
end

def get_image_url(mbid, title, artist, artist_mbid)
  puts '-' * 50
  puts "Getting #{mbid} #{artist} (#{artist_mbid}) #{title}"

  recordings = []
  recordings << get_musicbrainz_recording_from_release_id(mbid)
  sleep 1
  recordings = recordings.concat(strict_arid_search_musicbrainz_recordings(title.gsub('"', ''), artist_mbid))
  sleep 1
  recordings = recordings.concat(strict_search_musicbrainz_recordings(title.gsub('"', ''), artist))
  sleep 1
  recordings = recordings.compact

  release_ids = recordings.flat_map do |recording|
    releases = recording['releases']
    releases&.map { |r| r['id'] }
  end.compact

  if release_ids.empty?
    return search_spotify_track_for_image(artist, title.gsub('"', ''))
  end

  release_ids.each do |release_id|
    sleep 2

    url = "https://coverartarchive.org/release/#{release_id}"
    response = HTTParty.get(
      url,
      headers: {
        'Accept' => 'application/json',
        'Content-Type' => 'application/json',
        'User-Agent' => ENV['USER_AGENT']
      }
    )

    if response.success?
      image_file = response.parsed_response['images'].find { |img| img['front'] }['thumbnails']['250']
      if image_file && image_file != ''
        return image_file
      end
    else
      puts "Error fetching data from Cover Art Archive. MBID: #{release_id}. Response: #{response.body}"
    end
  end
end

def get_musicbrainz_recording_from_release_id(mbid)
  return if mbid.nil? || mbid == ''

  url = "#{MUSIC_BRAINZ_BASE_URL}/recording/#{mbid}?inc=releases&fmt=json"
  response = HTTParty.get(
    url,
    headers: {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'User-Agent' => ENV['USER_AGENT']
    }
  )

  if response.success?
    return response.parsed_response
  end

  puts "Error fetching data from Music Brainz. MBID: #{mbid}. Response: #{response.body}"
  nil
end

def strict_arid_search_musicbrainz_recordings(title, artist_mbid)
  return [] if artist_mbid.nil? || artist_mbid == ''

  base_url = "#{MUSIC_BRAINZ_BASE_URL}/recording"
  query = CGI.escape("'#{title}' AND arid:#{artist_mbid}")

  response = HTTParty.get(
    "#{base_url}?query=#{query}&inc=releases&fmt=json",
    headers: {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'User-Agent' => ENV['USER_AGENT']
    }
  )

  if response.success?
    return response.parsed_response['recordings']
  end

  puts "Error fetching data from Music Brainz (strict arid search). Title: #{title}. Artist MBID: #{artist_mbid}. Response: #{response.body}"
  []
end

def strict_search_musicbrainz_recordings(title, artist)
  base_url = "#{MUSIC_BRAINZ_BASE_URL}/recording"
  query = CGI.escape("'#{title}' AND artist:#{artist}")

  response = HTTParty.get(
    "#{base_url}?query=#{query}&inc=releases&fmt=json",
    headers: {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'User-Agent' => ENV['USER_AGENT']
    }
  )

  if response.success?
    return response.parsed_response['recordings']
  end

  puts "Error fetching data from Music Brainz (strict search). Title: #{title}. Artist: #{artist}. Response: #{response.body}"
  []
end

def fetch_spotify_access_token(client_id, client_secret)
  response = HTTParty.post(SPOTIFY_TOKEN_URL, {
    body: { grant_type: 'client_credentials' },
    headers: { 'Authorization' => "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}" }
  })

  if response.code == 200
    JSON.parse(response.body)['access_token']
  else
    puts "Error fetching Spotify token: #{response.body}"
    nil
  end
end

# Search Spotify API for a track by artist name and track title
def search_spotify_track_for_image(artist, title)
  access_token = fetch_spotify_access_token(ENV['SPOTIFY_CLIENT_ID'], ENV['SPOTIFY_CLIENT_SECRET'])
  return unless access_token


  query = "artist:#{artist} track:#{title}"
  response = HTTParty.get(SPOTIFY_SEARCH_URL, {
    query: { q: query, type: 'track', limit: 1 },
    headers: {
      'Authorization' => "Bearer #{access_token}",
      'Content-Type' => 'application/json'
    }
  })

  if response.success?
    result = response.parsed_response
    if result['tracks']['items'].any?
      track = result['tracks']['items'].first
      return track['album']['images']&.reverse.dig(0, 'url') # Smallest image
    else
      puts "No results found for '#{title}' by '#{artist}'"
      nil
    end
  else
    puts "Error in Spotify search: #{response.body}"
    nil
  end
end

# Update JSON file in GitHub repository
def update_github_file(tracks)
  client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])

  # Format track data
  track_data = tracks.map do |track|
    sleep 2

    mbid = track['mbid']
    title = track['name']
    artist = track['artist']['name']
    artist_mbid = track['artist']['mbid']
    image_url = get_image_url(mbid, title, artist, artist_mbid)

    {
      rank: track['@attr']['rank'].to_i,
      title: title,
      artist: artist,
      url: track['url'],
      img: image_url,
      playcount: track['playcount']
    }
  end

  # Prepare content
  content = JSON.pretty_generate(track_data)

  # Get file SHA if it exists
  begin
    file = client.contents(ENV['REPO'], path: ENV['FILE_PATH'])
    sha = file.sha
  rescue Octokit::NotFound
    sha = nil
  end

  # Update or create file
  client.create_contents(
    ENV['REPO'], ENV['FILE_PATH'], "Update top tracks (automated)", content, sha: sha
  )
  puts "Updated #{ENV['FILE_PATH']} in #{ENV['REPO']} repository."
end

# Main execution
tracks = fetch_top_tracks
update_github_file(tracks) unless tracks.empty?
