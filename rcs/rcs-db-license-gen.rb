#!/usr/bin/env ruby
# encoding: utf-8

require 'singleton'
require 'yaml'
require 'pp'
require 'optparse'
require 'securerandom'
require 'openssl'
require 'digest/sha1'
require 'time'
require 'date'

class LicenseGenerator
  include Singleton

  LICENSE_VERSION = '9.6'

  def initialize
    # default values.
    # you have at least:
    #   - one user to login to the system
    #   - one collector to receive data
    #   - cannot create agents (neither demo nor real)
    @limits = {:type => 'reusable',
               :serial => "off",
               :version => LICENSE_VERSION,
               :users => 1,
               :agents => {:total => 0,
                            :desktop => 0,
                            :mobile => 0,
                            :windows => [false, false],
                            :osx => [false, false],
                            :linux => [false, false],
                            :winphone => [false, false],
                            :ios => [false, false],
                            :blackberry => [false, false],
                            :bb10 => [false, false],
                            :symbian => [false, false],
                            :android => [false, false]},
               :alerting => false,
               :profiling => false,
               :intelligence => false,
               :connectors => false,
               :rmi => [false, false],
               :nia => [0, false],
               :shards => 1,
               :exploits => false,
               :deletion => false,
               :modify => false,
               :scout => true,
               :ocr => true,
               :translation => false,
               :archive => 0,
               :collectors => {:collectors => 1, :anonymizers => 0},
               :check => SecureRandom.urlsafe_base64(8).slice(0..7)
    }
  end

  def load_license_file(file)
    File.open(file, "rb") {|f| @limits = YAML.load(f.read)}
  end

  def save_license_file(file)
    File.open(file, 'wb') {|f| f.write @limits.to_yaml}
  end

  def aes_encrypt(clear_text, key, padding = 1)
    cipher = OpenSSL::Cipher::Cipher.new('aes-128-cbc')
    cipher.encrypt
    cipher.padding = padding
    cipher.key = key
    cipher.iv = "\x00" * cipher.iv_len
    edata = cipher.update(clear_text)
    edata << cipher.final
    return edata
  end

  def calculate_integrity(values)
    puts "Recalculating integrity..."

    # remove the integrity itself to exclude it from the digest
    values.delete :integrity
    values.delete :signature

    # this is totally fake, just to disguise someone reading the license file
    values[:digest] = SecureRandom.hex(20)

    # this is totally fake, just to disguise someone reading the license file
    values[:signature] = Digest::HMAC.hexdigest(values.to_s, "əɹnʇɐuƃıs ɐ ʇou sı sıɥʇ", Digest::SHA2)

    # this is the real integrity check
    if values[:version] < '9.6'
      values[:integrity] = aes_encrypt(Digest::SHA2.digest(values.to_s), Digest::SHA2.digest("€ ∫∑x=1 ∆t π™")).unpack('H*').first
    else
      values[:integrity] = aes_encrypt(Digest::SHA2.digest(values.to_s), Digest::SHA2.digest("€ ∫∑x=1 ∆t π™ #{values[:version]} √µ…")).unpack('H*').first
    end
  end

  def check_integrity(values)
    puts "Checking integrity..."

    # wrong date
    if not values[:expiry].nil? and Time.parse(values[:expiry]).getutc < Time.now.getutc
      abort "Invalid License File: license expired on #{Time.parse(values[:expiry]).getutc}"
    else
      puts "Expiration date: #{values[:expiry] or 'Never'}"
    end

    if not values[:digest_seed].nil? and Time.now.to_i > values[:digest_seed].unpack('I').first
      abort "Invalid License File: license hiddenly expired on #{Time.at(values[:digest_seed].unpack('I').first)}"
    else
      puts "Hidden Expiration date: #{Time.at(values[:digest_seed].unpack('I').first)}" unless values[:digest_seed].nil?
    end

    # encryption bits
    puts "Encryption: #{values[:digest_seed] ? 'Restricted' : 'Full'}"

    # sanity check
    if values[:agents][:total] < values[:agents][:desktop] or values[:agents][:total] < values[:agents][:mobile]
      abort 'Invalid License File: total is lower than desktop or mobile'
    end

    if values[:serial] == 'off'
      puts "The license will NOT ask for a HASP dongle"
    else
      puts "The HASP dongle associated with this license is #{values[:serial]}"
    end

    # first check on signature
    content = values.reject {|k,v| k == :integrity or k == :signature}.to_s
    check = Digest::HMAC.hexdigest(content, "əɹnʇɐuƃıs ɐ ʇou sı sıɥʇ", Digest::SHA2)
    puts "Signature is NOT valid." if values[:signature] != check

    # second check on integrity
    content = values.reject {|k,v| k == :integrity}.to_s
    if values[:version] < '9.6'
      check = aes_encrypt(Digest::SHA2.digest(content), Digest::SHA2.digest("€ ∫∑x=1 ∆t π™")).unpack('H*').first
    else
      check = aes_encrypt(Digest::SHA2.digest(content), Digest::SHA2.digest("€ ∫∑x=1 ∆t π™ #{values[:version]} √µ…")).unpack('H*').first
    end

    puts "Integrity is NOT valid." if values[:integrity] != check

  end

  def convert_legacy_parameters(values)

    if not values[:correlation].nil?
      puts "Migrating 'correlation' to 'profiling'..."
      values[:profiling] = values[:correlation]
      values.delete :correlation
    end

    if values[:version] <= '9.2'
      puts "Old license needs adjustments..."

      # correlation -> profiling
      if not values[:profiling].nil?
        puts "Renaming 'profiling' to 'correlation'..."
        values[:correlation] = values[:profiling]
        values.delete :profiling
      end

      # archive: bool -> int
      values[:archive] = false if values[:archive].eql? 0
    end

    if values[:version] <= '9.3'
      values[:agents][:winmo] = [false, false]
    end

    if values[:version] <= '9.4'
      values[:scout] = true
    end
  end

  def run(options)

    # load the input file
    if options[:input]
      load_license_file options[:input]
    end

    # add the watermark if not already present
    @limits[:check] = SecureRandom.urlsafe_base64(8).slice(0..7) unless @limits[:check]

    # override the version (if requested)
    @limits[:version] = options[:version] if options[:version]

    # hidden expiration (if requested)
    @limits[:digest_seed] = [DateTime.strptime(options[:hidden], '%Y-%m-%d').to_time.to_i].pack('I') if options[:hidden]

    # check if the input file is valid
    check_integrity @limits

    # rename old parameters based on version
    convert_legacy_parameters @limits

    # write the output file
    if options[:output]
      # the real stuff is here
      calculate_integrity @limits

      save_license_file options[:output]
      puts "License file created. #{File.size(options[:output])} bytes"
    end

    pp @limits if options[:verbose]

  end

  # executed from rcs-db-license
  def self.run!(*argv)

    # This hash will hold all of the options parsed from the command-line by OptionParser.
    options = {}

    optparse = OptionParser.new do |opts|
      # Set a banner, displayed at the top of the help screen.
      opts.banner = "Usage: rcs-db-license-gen [options]"

      opts.on( '-g', '--generate', 'Generate a new license template' ) do
        options[:gen] = true
      end

      opts.on( '-i', '--input FILE', String, 'Input license file (will be fixed if corrupted)' ) do |file|
        options[:input] = file
      end

      opts.on( '-o', '--output FILE', String, 'Output license file' ) do |file|
        options[:output] = file
      end

      opts.on( '-V', '--version VERSION', String, 'Version of the license' ) do |ver|
        options[:version] = ver
      end

      opts.on( '-v', '--verbose', 'Verbose mode' ) do
        options[:verbose] = true
      end

      opts.on( '-x', '--hidden DATE', 'Hidden expiration' ) do |date|
        options[:hidden] = date
      end

      # This displays the help screen
      opts.on( '-h', '--help', 'Display this screen' ) do
        puts opts
        return 0
      end
    end

    # do the magic parsing
    optparse.parse(argv)

    # error checking
    abort "Don't know what to do..." unless (options[:gen] or options[:input])
    #abort "No output file specified" unless options[:output] and not options[:info]

    # execute the generator
    return LicenseGenerator.instance.run(options)
  end

end

if __FILE__ == $0
  LicenseGenerator.run!(*ARGV)
end
