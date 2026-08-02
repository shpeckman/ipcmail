# src/ipcmail/address.cr
struct IPCMail::Address
  SCHEMES = %w[shm bus unix fifo]

  getter scheme : String
  getter target : String
  getter params : URI::Params

  def self.parse(uri : String) : Address
    parsed = URI.parse(uri)
    scheme = parsed.scheme
    raise ArgumentError.new("#{uri.inspect} has no scheme, expected one of #{SCHEMES.join(", ")}") unless scheme
    unless SCHEMES.includes?(scheme)
      raise ArgumentError.new("unsupported scheme #{scheme.inspect}, expected one of #{SCHEMES.join(", ")}")
    end

    target = "#{parsed.host}#{parsed.path}"
    raise ArgumentError.new("#{uri.inspect} has no target") if target.empty?
    new(scheme, target, parsed.query_params)
  end

  def initialize(@scheme : String, @target : String, @params : URI::Params)
  end

  def string?(*keys : String) : String?
    keys.each do |key|
      if value = @params[key]?
        return value
      end
    end
    nil
  end

  def integer?(*keys : String) : Int32?
    value = string?(*keys)
    return nil unless value
    value.to_i? || raise ArgumentError.new("#{value.inspect} is not an integer")
  end

  def boolean?(*keys : String) : Bool?
    value = string?(*keys)
    return nil unless value
    case value.downcase
    when "1", "true", "yes" then true
    when "0", "false", "no" then false
    else                         raise ArgumentError.new("#{value.inspect} is not a boolean")
    end
  end

  def mode? : Int32?
    value = string?("mode", "permissions")
    return nil unless value
    value.to_i?(8) || raise ArgumentError.new("#{value.inspect} is not an octal file mode")
  end

  def overflow? : Overflow?
    value = string?("overflow")
    return nil unless value
    Overflow.parse?(value) || raise ArgumentError.new("#{value.inspect} is not a known overflow policy")
  end

  def direction? : Pipe::Direction?
    value = string?("direction")
    return Pipe::Direction::Write if boolean?("write")
    return Pipe::Direction::Read if boolean?("read")
    return nil unless value
    Pipe::Direction.parse?(value) || raise ArgumentError.new("#{value.inspect} is not a known direction")
  end

  def framed? : Bool?
    if stream = boolean?("stream")
      return !stream
    end
    boolean?("framed")
  end
end
