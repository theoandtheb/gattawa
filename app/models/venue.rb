class Venue < ActiveRecord::Base
  include StripWhitespace

  has_paper_trail
  acts_as_taggable

  xss_foliate :sanitize => [:description, :access_notes]
  include DecodeHtmlEntitiesHack
  
  has_many :events, dependent: :nullify
  def future_events; events.future_with_venue; end
  def past_events; events.past_with_venue; end
  belongs_to :source

  has_many :artists, -> { uniq }, through: :events

  before_save :to_lower_case

  # Triggers
  strip_whitespace! :title, :description, :address, :url, :street_address, :locality, :region, :postal_code, :country, :email, :telephone
  # before_save :geocode!
  # before_update :geocode!

  # Validations
  validates_presence_of :title
  validates_format_of :url,
    :with => /(http|https):\/\/(\w+:{0,1}\w*@)?(\S+)(:[0-9]+)?(\/|\/([\w#!:.?+=&%@!\-\/]))?/,
    :allow_blank => true,
    :allow_nil => true
  validates_inclusion_of :latitude,
    :in => -90..90,
    :allow_nil => true,
    :message => "must be between -90 and 90"
  validates_inclusion_of :longitude,
    :in => -180..180,
    :allow_nil => true,
    :message => "must be between -180 and 180"

  validates :title, :description, :address, :url, :street_address, :locality, :region, :postal_code, :country, :email, :telephone, blacklist: true

  # Duplicates
  include DuplicateChecking
  duplicate_checking_ignores_attributes    :source_id, :version, :closed, :wifi, :access_notes
  duplicate_squashing_ignores_associations :tags, :base_tags, :taggings

  # Named scopes
  scope :masters,          -> { where(duplicate_of_id: nil).includes(:source, :events, :tags, :taggings) }
  scope :with_public_wifi, -> { where(wifi: true) }
  scope :in_business,      -> { where(closed: false) }
  scope :out_of_business,  -> { where(closed: true) }

  #===[ Finders ]=========================================================

  # Return Hash of Venues grouped by the +type+, e.g., a 'title'. Each Venue
  # record will include an <tt>events_count</tt> field containing the number of
  # events at the venue, which improves performance for displaying these.
  def self.find_duplicates_by_type(type='na')
    case type
    when 'na', nil, ''
      # The LEFT OUTER JOIN makes sure that venues without any events are also returned.
      return { [] => \
        self.where('venues.duplicate_of_id IS NULL').order('LOWER(venues.title)')
      }
    else
      kind = %w[all any].include?(type) ? type.to_sym : type.split(',').map(&:to_sym)

      return self.find_duplicates_by(kind, 
        :grouped  => true, 
        :where    => 'a.duplicate_of_id IS NULL AND b.duplicate_of_id IS NULL'
      )
    end
  end

  #===[ Search ]==========================================================

  def self.search(query, opts={})
    SearchEngine.search(query, opts)
  end

  #===[ Overrides ]=======================================================

  def url=(value)
    super UrlPrefixer.prefix(value)
  end

  #===[ Address helpers ]=================================================

  # Does this venue have any address information?
  def has_full_address?
    [street_address, locality, region, postal_code, country].any?(&:present?)
  end

  # Display a single line address.
  def full_address
    if has_full_address?
      "#{street_address}, #{locality} #{region} #{postal_code} #{country}"
    end
  end

  #===[ Geocoding helpers ]===============================================

  # Get an address we can use for geocoding
  def geocode_address
    full_address or address
  end

  # Return this venue's latitude/longitude location,
  # or nil if it doesn't have one.
  def location
    if [latitude, longitude].all?(&:present?)
      [latitude, longitude]
    end
  end

  attr_accessor :force_geocoding

  def geocode!
    Geocoder.geocode(self)
    true # Try to geocode, but don't complain if we can't.
  end
  # obfuscate_id

  def to_s
    "#{ name.titleize unless name.nil? }"
  end

  def self.deauth_all
    Venue.all.each do |f|
      f.authorized = false
    end
  end

  def rewite_dupes
    @dupe_venues = Venue.where(title: self.original_title).ids
    @dupe_events = []
    @dupe_venues.each do |d|
      @dupe_events << Event.where(venue_id: d).ids
    end
    @dupe_events = @dupe_events.flatten
    @dupe_events.each do |f|
      @event = Event.find(f)
      @event.venue_id = self.id
      @event.save!
    end
    @dupe_venues.delete(self.id)
    unless @dupe_venues == []
      @dupe_venues.each do |t|
        @venue = Venue.find(t)
        @venue.destroy
      end
    end
  end

  private
    def to_lower_case
      self.name = name.downcase unless name.nil?
    end
end
