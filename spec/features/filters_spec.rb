require 'spec_helper'

describe 'Dashboard filters', js: true do
  let(:senior_role) { create(:admin_role) }
  let(:role) { create(:role_billable) }
  let(:user) { create(:user, admin_role_id: senior_role.id) }
  let!(:dev_user) { create(:user, last_name: 'Developer', first_name: 'Daisy', admin_role_id: senior_role.id) }
  let!(:membership) { create(:membership, user: dev_user, project: project_test, role: role) }
  let!(:project_zztop) { create(:project, name: 'zztop') }
  let!(:project_test) { create(:project, name: 'test') }
  before(:each) do
    page.set_rack_session 'warden.user.user.key' => User.serialize_into_session(user).unshift('User')
    visit '/'
  end

  describe 'users filter' do
    it 'returns only matched projects when user name provided' do
      select_option('users', 'Developer Daisy')
      expect(page).to have_text('test')
      page.should have_no_content('zztop')
    end

    it 'returns all projects when no selectize provided' do
      expect(page).to have_text('zztop')
      expect(page).to have_text('test')
    end
  end
end
