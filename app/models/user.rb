require 'csv'

class User
  include Mongoid::Document
  devise :database_authenticatable, :registerable,
         :trackable, :validatable, :omniauthable, omniauth_providers: [:google_oauth2, :github]

  include Mongoid::Timestamps
  include Mongoid::Paranoia

  field :encrypted_password
  field :sign_in_count, type: Integer, default: 0
  field :current_sign_in_at, type: Time
  field :last_sign_in_at, type: Time
  field :current_sign_in_ip
  field :last_sign_in_ip
  field :team_join_time, type: DateTime
  field :oauth_token
  field :refresh_token
  field :oauth_expires_at, type: DateTime

  field :first_name
  field :last_name
  field :email
  field :gh_nick
  field :skype
  field :employment, type: Integer, default: 0
  field :phone
  field :archived, type: Mongoid::Boolean, default: false
  field :available, type: Mongoid::Boolean, default: true
  field :without_gh, type: Mongoid::Boolean, default: false
  field :uid, type: String
  field :user_notes, type: String

  mount_uploader :gravatar, GravatarUploader

  index({ email: 1, deleted_at: 1 })

  has_many :memberships, dependent: :destroy
  has_many :notes
  has_many :positions
  has_one :vacation, inverse_of: :user
  belongs_to :admin_role
  belongs_to :role
  belongs_to :contract_type
  belongs_to :location
  belongs_to :team, inverse_of: :user
  belongs_to :leader_team, class_name: 'Team', inverse_of: :leader
  has_and_belongs_to_many :abilities

  validates :first_name, :last_name, presence: true
  validates :email, presence: true, uniqueness: true
  validates :employment, inclusion: { in: 0..200, message: 'must be between 0-200' }
  validates :phone, length: { maximum: 16 },
                    format: { with: %r{\A[+]?\d+(?>[- .]\d+)*\z} },
                    allow_blank: true
  validates :archived, inclusion: { in: [true, false] }

  scope :by_name, -> { asc(:first_name, :last_name) }
  scope :by_last_name, -> { asc(:last_name, :first_name) }
  scope :available, -> { where(available: true) }
  scope :active, -> { where(archived: false) }
  scope :technical_active, -> { where(archived: false, available: true) }
  scope :roles, -> (roles) { where(:role.in => roles) }
  scope :contract_users, ->(contract_type) {
    ContractType.where(name: contract_type).first.try(:users)
  }
  scope :without_team, -> { where(team: nil) }
  scope :in_a_project_for_over, lambda { |time|
    project_ids = Project.where(potential: false, archived: false).only(:_id).map(&:_id)
    user_ids = Membership.unfinished.where(:starts_at.lt => time.try(:ago)).in(project_id: project_ids)
      .only(:user_id).map(&:user_id)
    User.in(_id: user_ids)
  }

  before_save :end_memberships
  before_update :save_team_join_time
  before_validation :assign_abilities

  def self.create_from_google!(params)
    user = User.where(uid: params['uid']).first
    user = User.where(email: params['info']['email']).first if user.blank?
    if user.present?
      user.update_attributes(uid: params['uid']) if user.uid.blank?
      user.update_attributes(oauth_token: params['credentials']['token'])
      user.update_attributes(refresh_token: params['credentials']['refresh_token']) if user.refresh_token.nil?
      user.update_attributes(oauth_expires_at: params['credentials']['expires_at'])
      return user
    end
    fields = %w(first_name last_name email)
    attributes = fields.reduce({}) { |mem, key| mem.merge(key => params['info'][key]) }
    attributes['password'] = Devise.friendly_token[0, 20]
    attributes['uid'] = params['uid']
    attributes['oauth_token'] = params['credentials']['token']
    attributes['refresh_token'] = params['credentials']['refresh_token']
    attributes['oauth_expires_at'] = params['credentials']['expires_at']
    UserMailer.notify_operations(params['info']['email']).deliver
    SendMailJob.new.async.perform(UserMailer, :notify_operations, params['info']['email'])
    User.create!(attributes)
  end

  def self.get_from_api(params)
    User.where(id: params['id']).first || User.where(email: params['email']).first
  end

  def flat_memberships
    membs_grouped = memberships.group_by { |m| m.project.api_slug }
    membs_grouped.each do |slug, membs|
      membs_grouped[slug] = {
        starts_at: (membs.map(&:starts_at).include?(nil) ? nil : membs.map(&:starts_at).compact.min),
        ends_at: (membs.map(&:ends_at).include?(nil) ? nil : membs.map(&:ends_at).compact.max),
        role: (membs.map { |memb| memb.role.try(:name) }).last
      }
    end
  end

  def months_in_current_project
    longest_current_membership = current_memberships.min_by { |m| m.starts_at }
    return 0 if longest_current_membership.nil?
    # 60 seconds * 60 minutes * 24 hours * 30.44 days in a month on average
    (Time.now - longest_current_membership.starts_at) / (60*60*24*30.44)
  end

  def github_connected?
    gh_nick.present? || without_gh == true
  end

  def potential_projects
    @potential_projects ||= map_projects(potential_memberships)
  end

  def memberships_cached
    @memberships ||= memberships.to_a
  end

  def booked_memberships
    memberships.select(&:booked).select(&:ends_at).sort_by(&:ends_at)
  end

  def potential_memberships
    @potential_project_ids ||= Project.where(potential: true).only(:_id).map(&:_id)
    potential_memberships_by_ids @potential_project_ids
  end

  def current_projects_with_memberships
    @current_projects ||= map_projects(current_memberships)
  end

  def current_projects
    current_projects_with_memberships.map{ |p| p[:project] }
  end

  def current_memberships
    @nonpotential_project_ids ||= Project.where(potential: false, archived: false).only(:_id).map(&:_id)
    current_memberships_by_project_ids @nonpotential_project_ids
  end

  def last_membership
    without_date = current_memberships.reject(&:ends_at)
    return without_date.last if without_date.present?
    current_memberships.select(&:ends_at).sort_by(&:ends_at).last
  end

  def current_project
    memberships.active.current_active.present? ? memberships.active.current_active.first.project : nil
  end

  def current_memberships_by_project_ids(project_ids)
    memberships_by_project_ids(project_ids).select { |m| m.starts_at <= Time.now }
  end

  def memberships_by_project_ids(project_ids)
    now = Time.now
    memberships_cached.select { |m| project_ids.include?(m.project_id) && (m.ends_at.nil? || m.ends_at >= now) && !m.booked? }
  end

  def potential_memberships_by_ids(project_ids)
    now = Time.now
    memberships_cached.select { |m| project_ids.include?(m.project_id) && (m.ends_at.nil? || m.ends_at >= now) }
  end

  %w(current potential next).each do |type|
    type += '_projects'
    define_method("has_#{type}?") do
      send(type).present?
    end
  end

  def next_memberships
    now = Time.now
    memberships_cached.select { |m| m.starts_at >= now && (m.ends_at.nil? || m.ends_at >= now) && !m.project_potential? && !m.booked? }
  end

  def next_projects
    @next_projects ||= map_projects(next_memberships)
  end

  def memberships_by_project
    @project ||= Project.unscoped do
      memberships.includes(:project, :role).sort(starts_at: -1).group_by(&:project_id).each_with_object({}) do |data, memo|
        memberships = data[1].sort { |m1, m2| m2.starts_at <=> m1.starts_at }
        project = memberships.first.project
        memo[project] = MembershipDecorator.decorate_collection memberships
      end
    end
  end

  def end_memberships
    memberships.each(&:end_now!) if archived_change && archived_change.last
  end

  def admin?
    admin_role.present?
  end

  def self.by_name
    all.sort_by { |u| u.first_name.downcase }
  end

  def self.by_vacation_date
    all.decorate.select { |u| u.vacation.present? }.sort_by { |u| u.vacation.starts_at }
  end

  def abilities_names
    abilities.map(&:name)
  end

  def abilities_names=(abilities_list)
    @abilities_list = abilities_list
  end

  private

  def save_team_join_time
    if team_id_changed?
      team_join_val = team_id.present? ? DateTime.now : nil
      assign_attributes(team_join_time: team_join_val)
    end
  end

  def assign_abilities
    if @abilities_list.present?
      @abilities_list.reject!(&:empty?)
      self.abilities = @abilities_list.map { |name| Ability.find_or_initialize_by(name: name) }
    end
  end

  def map_projects(membership)
    membership.map { |c_ms| { project: c_ms.project, billable: c_ms.billable, membership: c_ms } }
  end
end
