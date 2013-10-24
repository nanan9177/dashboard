class ActivitiesController < ApplicationController
  include LevelsHelper
  protect_from_forgery except: :milestone
  check_authorization except: [:milestone]
  load_and_authorize_resource except: [:milestone]

  before_action :set_activity, only: [:show, :edit, :update, :destroy]

  def milestone
    solved = 'true' == params[:result]
    test_result = params[:testResult].to_i
    script_level = ScriptLevel.find(params[:script_level_id], include: [:script, :level])
    level = script_level.level
    trophy_updates = []

    if current_user
      authorize! :create, Activity
      authorize! :create, UserLevel

      Activity.create!(
          user: current_user,
          level: level,
          action: solved,
          test_result: test_result,
          attempt: params[:attempt].to_i,
          time: params[:time].to_i,
          data: params[:program])

      user_level = UserLevel.find_or_create_by_user_id_and_level_id(current_user.id, level.id)
      user_level.attempts += 1
      user_level.best_result = user_level.best_result ?
          [test_result, user_level.best_result].max :
          test_result
      user_level.save!

      begin
        trophy_updates = trophy_check(current_user)
      rescue Exception => e
        Rails.logger.error "Error updating trophy exception: #{e.inspect}"
      end
    end

    # if they solved it, figure out next level
    if solved
      response = {}
      
      if (trophy_updates.length > 0)
        response[:trophy_updates] = trophy_updates
      end
      
      next_level = script_level.next_level
      if next_level
        response[:redirect] = build_script_level_path(next_level)
      
        if (level.game_id != next_level.level.game_id)
          response[:stage_changing] = {
              previous: { number: level.game_id, name: level.game.name },
              new: { number: next_level.level.game_id, name: next_level.level.game.name }
              }
        end
        
        if (level.skin != next_level.level.skin)
          response[:skin_changing] = { previous: level.skin,
            new: next_level.level.skin }
        end
      else
        response[:message] = 'no more levels'
      end
      render json: response
    else
      render json: { message: 'try again' }
    end
  end

  # GET /activities
  # GET /activities.json
  def index
    @activities = Activity.all
  end

  # GET /activities/1
  # GET /activities/1.json
  def show
  end

  # GET /activities/new
  def new
    @activity = Activity.new
  end

  # GET /activities/1/edit
  def edit
  end

  # POST /activities
  # POST /activities.json
  def create
    @activity = Activity.new(activity_params)

    respond_to do |format|
      if @activity.save
        format.html { redirect_to @activity, notice: 'Activity was successfully created.' }
        format.json { render action: 'show', status: :created, location: @activity }
      else
        format.html { render action: 'new' }
        format.json { render json: @activity.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /activities/1
  # PATCH/PUT /activities/1.json
  def update
    respond_to do |format|
      if @activity.update(activity_params)
        format.html { redirect_to @activity, notice: 'Activity was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @activity.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /activities/1
  # DELETE /activities/1.json
  def destroy
    @activity.destroy
    respond_to do |format|
      format.html { redirect_to activities_url }
      format.json { head :no_content }
    end
  end

  def trophy_check(user)
    trophy_updates = []
    # called after a new activity is logged to assign any appropriate trophies
    current_trophies = user.user_trophies.includes([:trophy, :concept]).index_by { |ut| ut.concept }
    progress = user.concept_progress

    progress.each_pair do |concept, counts|
      current = current_trophies[concept]
      pct = counts[:current].to_f/counts[:max]

      new_trophy = Trophy.find_by_id case
        when pct == 1
          Trophy::GOLD
        when pct >= 0.5
          Trophy::SILVER
        when pct >= 0.2
          Trophy::BRONZE
        else
          # "no trophy earned"
      end

      if new_trophy
        if new_trophy.id == current.try(:trophy_id)
          # they already have the right trophy
        elsif current
          current.update_attributes!(trophy_id: new_trophy.id)
          trophy_updates << [concept.description, new_trophy.name, view_context.image_path(new_trophy.image_name)]
        else
          UserTrophy.create!(user: user, trophy_id: new_trophy.id, concept: concept)
          trophy_updates << [concept.description, new_trophy.name, view_context.image_path(new_trophy.image_name)]
        end
      end
    end

    trophy_updates
  end

  private
  # Use callbacks to share common setup or constraints between actions.
  def set_activity
    @activity = Activity.find(params[:id])
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def activity_params
    params[:activity]
  end
end
