class Project
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia
  include Mongoid::History::Trackable
  include Project::UserAvailability

  after_save :update_membership_fields
  after_save :check_potential
  before_save :set_initials
  before_save :set_colour

  SOON_END = 1.week
  POSSIBLE_TYPES = %w(regular maintenance_support maintenance_development).freeze

  field :name
  field :slug
  field :end_at, type: Time
  field :archived, type: Mongoid::Boolean, default: false
  field :potential, type: Mongoid::Boolean, default: false
  field :internal, type: Mongoid::Boolean, default: false
  field :kickoff, type: Date
  field :project_type, default: POSSIBLE_TYPES.first
  field :colour
  field :initials
  field :toggl_bookmark

  index({ deleted_at: 1 })

  has_many :memberships, dependent: :destroy
  has_many :notes
  accepts_nested_attributes_for :memberships

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :slug, allow_blank: true, allow_nil: true, uniqueness: true,
    format: { with: /\A[a-z\d]+\Z/ }
  validates :archived, inclusion: { in: [true, false] }
  validates :potential, inclusion: { in: [true, false] }
  validates :project_type, inclusion: { in: POSSIBLE_TYPES }

  scope :active, -> { where(archived: false) }
  scope :nonpotential, -> { active.where(potential: false) }
  scope :potential, -> { active.where(potential: true) }
  POSSIBLE_TYPES.each do |possible_type|
    scope possible_type, -> { active.where(project_type: possible_type) }
  end
  scope :maintenance_development, -> { active.where(maintenance_development: true) }
  scope :ending_in_a_week, -> { active.between(end_at: (SOON_END.from_now - 1.day)..SOON_END.from_now) }
  scope :ending_soon, -> { active.between(end_at: Time.now..SOON_END.from_now) }
  scope :starting_tomorrow, -> { potential.between(kickoff: Time.now..1.day.from_now) }
  scope :ending_in, ->(days) { between(end_at: Time.now..days.days.from_now) }
  scope :starting_in, ->(x) { between(kickoff: Time.now..x.days.from_now) }
  scope :ending_or_starting_in, lambda { |days|
    any_of(ending_in(days).selector, starting_in(days).selector)
  }

  track_history on: [:archived, :potential], version_field: :version, track_create: true, track_update: true

  def to_s
    name
  end

  def api_slug
    slug.blank? ? name.try(:delete, '^a-zA-Z').try(:downcase) : slug
  end

  def pm
    pm_membership = memberships.with_role(Role.pm).select(&:active?).first
    pm_membership.try(:user)
  end

  def self.three_months_old
    Project.nonpotential.select{ |p| p.nonpotential_switch.to_date == 3.months.ago.to_date }
  end

  def self.search(search)
    Project.where(name: /#{search}/i)
  end

  def starting_in?(days)
    Project.starting_in(days).where(id: id).exists?
  end

  def ending_in?(days)
    Project.ending_in(days).where(id: id).exists?
  end

  def nonpotential_switch
    last_track = history_tracks.select do |h|
      h.modified && h.modified['potential'] == false
    end.last

    last_track.present? ? last_track.created_at : created_at
  end

  def self.upcoming_changes(days)
    projects = Membership.includes(:project)
                .upcoming_changes(days)
                .map(&:project)
    projects << Project.ending_or_starting_in(days).to_a
    projects.uniq.flatten
  end

  def self.by_name
    all.sort_by{ |p| p.name.downcase }
  end

  POSSIBLE_TYPES.each do |possible_type|
    define_method "#{possible_type}?" do
      project_type == possible_type
    end
  end

  private

  def update_membership_fields
    if potential_change == [true, false] || archived_change == [true, false]
      memberships.each do |membership|
        membership.update(project_potential: potential, project_archived: archived)
      end
    end
  end

  def check_potential
    if potential_change == [true, false]
      set_proper_membership_dates
    end
  end

  def set_proper_membership_dates
    memberships.each do |membership|
      if membership.stays
        membership.update(starts_at: Time.now)
      else
        membership.destroy
      end
    end
  end

  def set_initials
    camel_case = name.underscore.split('_')
    splitted = camel_case.count > 1 ? camel_case : name.split
    self.initials = splitted[0..1].map { |w| w[0] }.join.upcase
  end

  def hsv_to_rgb(h, s, v)
    h_i = (h * 6).to_i
    f = h * 6 - h_i
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    case h_i
    when 0 then r, g, b = v, t, p
    when 1 then r, g, b = q, v, p
    when 2 then r, g, b = p, v, t
    when 3 then r, g, b = p, q, v
    when 4 then r, g, b = t, p, v
    when 5 then r, g, b = v, p, q
    end
    [r, g, b].map { |color| (color * 256).to_i.to_s(16) }
  end

  def set_colour
    golden_ratio_conjugate = 0.618033988749895
    h = rand
    h += golden_ratio_conjugate
    h %= 1
    self.colour ||= "#" + hsv_to_rgb(h, 0.5, 0.95).join
  end
end
