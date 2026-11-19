module EcoNet
  class Error < Exception
  end

  class InvalidCredentialsError < Error
  end

  class InvalidResponseFormat < Error
  end

  class GenericHTTPError < Error
    getter status_code : Int32

    def initialize(@status_code : Int32)
      super("EcoNet returned HTTP #{@status_code}")
    end
  end

  class ConnectionError < Error
  end
end
