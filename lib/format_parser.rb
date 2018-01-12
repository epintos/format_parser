require 'thread'

module FormatParser
  require_relative 'image'
  require_relative 'audio'
  require_relative 'io_utils'
  require_relative 'read_limiter'
  require_relative 'remote_io'
  require_relative 'io_constraint'
  require_relative 'care'
  require_relative 'parser_helpers'

  PARSER_MUX = Mutex.new

  def self.register_parser_constructor(object_responding_to_new)
    PARSER_MUX.synchronize do
      @parsers ||= []
      @parsers << object_responding_to_new
      # Gathering natures from parsers.
      @natures ||= Set.new
      @natures.add(*object_responding_to_new.natures)
      @formats ||= Set.new
      @formats.add(*object_responding_to_new.formats)
    end
  end

  def self.parse_http(url)
    remote_io = RemoteIO.new(url)
    cached_io = Care::IOWrapper.new(remote_io)

    # Prefetch the first page, since it is very likely to be touched
    # by all parsers anyway. Additionally, when using RemoteIO we need
    # to explicitly obtain the size of the resource, which is only available
    # after having performed at least one successful GET - at least on S3
    cached_io.read(1); cached_io.seek(0)

    parse(cached_io)
  end

  def self.parse(io, natures: @natures.to_a, formats: @formats.to_a, limit: @parsers.length)
    # If the cache is preconfigured do not apply an extra layer. It is going
    # to be preconfigured when using parse_http.
    io = Care::IOWrapper.new(io) unless io.is_a?(Care::IOWrapper)
    results = []

    # Always instantiate parsers fresh for each input, since they might
    # contain instance variables which otherwise would have to be reset
    # between invocations, and would complicate threading situations
    parsers = @parsers.select { |p| p.any_format?(formats) && p.any_nature?(natures) }.map(&:new)

    parsers.each do |parser|
      # We need to rewind for each parser, anew
      io.seek(0)
      # Limit how many operations the parser can perform
      limited_io = ReadLimiter.new(io, max_bytes: 512*1024, max_reads: 64*1024, max_seeks: 64*1024)
      begin
        if info = parser.call(limited_io)
          results << info
          # Return early if the limit was hit.
          return results if results.length == limit
        end
      rescue IOUtils::InvalidRead
        # There was not enough data for this parser to work on,
        # and it triggered an error
      rescue ReadLimiter::BudgetExceeded
        # The parser tried to read too much - most likely the file structure
        # caused the parser to go off-track. Strictly speaking we should log this
        # and examine the file more closely.
      end
    end
    # Return the array of results.
    results
  end

  Dir.glob(__dir__ + '/parsers/*.rb').sort.each do |parser_file|
    require parser_file
  end
end
