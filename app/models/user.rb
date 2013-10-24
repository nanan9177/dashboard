class User < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :token_authenticatable, :confirmable,
  # :lockable, :timeoutable
  devise :database_authenticatable, :registerable, :omniauthable,
         :recoverable, :rememberable, :trackable, :validatable, :authentication_keys => [:login]

  PROVIDER_MANUAL = 'manual'

  attr_accessor :login

  has_many :user_levels
  has_many :sections

  has_many :user_trophies
  has_many :trophies, through: :user_trophies, source: :trophy

  has_many :followers
  has_many :followeds, :class_name => 'Follower', :foreign_key => 'student_user_id'

  has_many :students, through: :followers, source: :student_user
  has_many :teachers, through: :followeds, source: :user

  validates_format_of :email, with: Devise::email_regexp, allow_blank: true, on: :create
  #validates_length_of :first_name, maximum: 35
  #validates_length_of :last_name, maximum: 35
  validates_length_of :name, within: 1..70
  validates_length_of :email, maximum: 255
  # this is redundant to devise, but required for tests?
  validates_uniqueness_of :email, allow_nil: true, allow_blank: true, case_sensitive: false
  validates_length_of :parent_email, maximum: 255
  validates_length_of :username, within: 5..20
  validates_format_of :username, with: /\A[a-z0-9\-\_\.]+\z/i, on: :create
  validates_uniqueness_of :username, allow_nil: false, allow_blank: false, case_sensitive: false

  def self.from_omniauth(auth)
    where(auth.slice(:provider, :uid)).first_or_create do |user|
      user.provider = auth.provider
      user.uid = auth.uid
      user.username = auth.info.nickname
      user.name = auth.info.name
      user.email = auth.info.email
    end
  end

  def self.new_with_session(params, session)
    if session["devise.user_attributes"]
      new(session["devise.user_attributes"]) do |user|
        user.attributes = params
        user.valid?
      end
    else
      super
    end
  end

  def password_required?
    super && (provider.blank? || (User::PROVIDER_MANUAL == provider))
  end

  def email_required?
    User::PROVIDER_MANUAL != provider
  end

  def update_with_password(params, *options)
    if encrypted_password.blank?
      update_attributes(params, *options)
    else
      super
    end
  end

  def self.find_first_by_auth_conditions(warden_conditions)
    conditions = warden_conditions.dup
    if login = conditions.delete(:login)
      where(conditions).where(['username = :value OR email = :value', { :value => login.downcase }]).first
    else
      where(conditions).first
    end
  end

  def levels_from_script(script, game_index=nil)
    ul_map = self.user_levels.includes({level: [:game, :concepts]}).index_by(&:level_id)
    q = script.script_levels.includes({ level: :game }, :script).order(:chapter)

    if game_index
      q = q.where(['games.id = :index', { :index => game_index}]).references(:game)
    end

    q.each do |sl|
      ul = ul_map[sl.level_id]
      sl.user_level = ul
    end
  end

  def next_untried_level(script)
    ScriptLevel.find_by_sql(<<SQL).first
select sl.*
from script_levels sl
left outer join user_levels ul on ul.level_id = sl.level_id and ul.user_id = #{self.id}
    where sl.script_id = #{script.id} and (ul.best_result is null or ul.best_result < #{Activity::MINIMUM_PASS_RESULT})
order by sl.chapter
limit 1
SQL
  end

  def progress(script)
    self.connection.select_one(<<SQL)
select
    count(case when ul.best_result >= #{Activity::MINIMUM_PASS_RESULT} then 1 else null end) as current_levels,
  count(*) as max_levels,
  (select count(*) from user_trophies where user_id = #{self.id}) as current_trophies,
  (select count(*) from concepts) as max_trophies
from script_levels sl
left outer join user_levels ul on ul.level_id = sl.level_id and ul.user_id = #{self.id}
where sl.script_id = #{script.id}
SQL
  end

  def concept_progress
    # todo: cache everything but the user's progress
    user_levels_map = self.user_levels.includes([{level: :concepts}]).index_by(&:level_id)
    user_trophy_map = self.user_trophies.includes(:trophy).index_by(&:concept_id)
    result = Hash.new{|h,k| h[k] = {obj: k, current: 0, max: 0}}

    Level.all.includes(:concepts).each do |level|
      level.concepts.each do |concept|
        result[concept][:current] += 1 if user_levels_map[level.id].try(:best_result).to_i >= #{Activity::MINIMUM_PASS_RESULT}
        result[concept][:max] += 1
        result[concept][:trophy] ||= user_trophy_map[concept.id]
      end
    end
    result
  end

  def last_attempt(level)
    Activity.where(user_id: self.id, level_id: level.id).order('id desc').first
  end

  # returns a map from section to the users in that section
  def students_by_section
    class_map = Hash.new{ |h,k| h[k] = [] }
    self.followers.includes([:section, :student_user]).each do |f|
      class_map[f.section] << f.student_user
    end
    class_map
  end

  #TODO Store locale instead of language in database.
  # Language and region should be parsed out of locale if needed.

  def language
    read_attribute(:language) || 'en'
  end

  def region
    'us'
  end

  def locale
    "#{language}_#{region}"
  end
end
