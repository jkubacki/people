class NotesController < ApplicationController

  include Shared::RespondsController

  expose :note, attributes: :note_params

  before_filter :authenticate_admin!

  def create
    if note.save
      SendMailJob.new.async.perform(NoteMailer, :note_added, note)
      respond_on_success note
    else
      respond_on_failure note.errors
    end
  end

  def show
  end

  def update
    if note.save
      respond_on_success note
    else
      respond_on_success note.errors
    end
  end

  def destroy
    if note.destroy
      respond_to do |format|
        format.html { redirect_to note, notice: 'Note deleted!' }
        format.json { render json: { }, status: 204 }
      end
    else
      respond_to do |format|
        format.html { redirect_to note, alert: 'Something went wrong. Destroy unsuccessful.' }
        format.json { render json: { errors: note.errors }, status: 400 }
      end
    end
  end

  private

  def note_params
    params.require(:note).permit(:text, :open, :project_id, :user_id)
  end
end
