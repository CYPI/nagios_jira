#!/usr/bin/ruby

require 'rubygems'
require 'net/https'
require 'pp'
require 'yaml'
require 'json'
require 'logger'


logger = Logger.new(STDERR)
logger = Logger.new(STDOUT)
logger = Logger.new(configuration['log_file_path'])

configuration = YAML::load_file('/etc/nagios3/nagios_to_jira_config')

$jira_authorization = configuration['JIRA_AUTHORIZATION']
$jira_url = configuration['JIRA_URL']
jira_project_id = configuration['jira_project_id']
jira_project_key = configuration['jira_project_key']
jira_issue_type = configuration['jira_issue_type']
jira_open_transition_id = configuration['jira_open_transition_id']
jira_close_transition_id = configuration['jira_close_transition_id']
jira_warning_priority_id = configuration['jira_warning_priority_id']
jira_critical_priority_id = configuration['jira_critical_priority_id']
jira_custom_field_id = configuration['jira_custom_field_id']
jira_issue_closed_id = configuration['jira_issue_closed_id']
log_file = configuration['log_file_path']
logger = Logger.new(log_file)

def api_call(method, endpoint, body = '', fqdn = $jira_url)
  url = URI(fqdn + endpoint)
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = case method
            when 'GET'    then Net::HTTP::Get.new(url)
            when 'POST'   then Net::HTTP::Post.new(url)
            when 'PUT'    then Net::HTTP::Put.new(url)
            when 'DELETE' then Net::HTTP::Delete.new(url)
            end
  if body
    request.body = body
  end
  request["Content-Type"] = 'application/json'
  request["authorization"] = $jira_authorization
  request["Cache-Control"] = 'no-cache'
  response = http.request(request)
  if method == 'PUT'
    return ''
  else
    return JSON.parse(response.read_body)
  end

end

def jira_create_issue(jira_project_id, issue_summary, jira_issue_type,
                      issue_priority, issue_body, jira_custom_field_id, jira_custom_field_value)
  payload = {
      fields: {
          project:
              {
                  id: jira_project_id
              },
          summary: issue_summary,
          description: issue_body,
          issuetype: {
              name: jira_issue_type
          },
          "customfield_#{jira_custom_field_id}" => "#{jira_custom_field_value}",
          priority: {
              name: issue_priority}
      }
  }

  result = api_call('POST', "issue/", payload.to_json)
  return result

end



def priority_for_state(state, warning_priority, critical_priority)
  if ['DOWN', 'UNREACHABLE', 'CRITICAL', 'UNKNOWN'].include?(state)
    critical_priority
  else
    warning_priority
  end
end

def nagios_value_for(var, default = '')
  ENV["NAGIOS_#{var}"] || default
end

def transition_to(transition_id, issue, comment = '')
  payload = {
      update: {comment: [ { add: {body: comment} }]},
      transition: {id: transition_id}
  }

  result = api_call('POST', "issue/#{issue["key"]}/transitions?expand=transitions", payload.to_json)
  return result
end

def comment_on(issue, comment)
  payload = {
      body: comment
  }

  result = api_call('POST', "issue/#{issue["key"]}/comment", payload.to_json)
  return result
end

def update_issue(issue, attribute, value)
  payload = {
      update: {
          "#{attribute}" => [
              {
                  "set" => "#{value}"
              }
          ]
      }
  }

  result = api_call('PUT', "issue/#{issue["key"]}", payload.to_json)
  return result
end

def jira_search_issues(jql)
  payload = {
      jql: jql
  }
  result = api_call('POST', 'search', payload.to_json)
  return result
end

unless ENV['NAGIOS_HOSTPROBLEMID'].nil?
  logger.info "host issue"
  nagios_problem_type = 'host'
  nagios_problem_id = nagios_value_for('HOSTPROBLEMID')
  nagios_state = nagios_value_for('HOSTSTATE')
  last_nagios_state = nagios_value_for('LASTHOSTSTATE', 'UNKOWN')
  nagios_notes_url = nagios_value_for('HOSTNOTESURL')
  nagios_action_url = nagios_value_for('HOSTACTIONURL')
  nagios_output = nagios_value_for('HOSTOUTPUT')
  nagios_long_output = nagios_value_for('LONGHOSTOUTPUT')
  nagios_service_notes = nagios_value_for('HOSTNOTES')
  issue_summary = nagios_value_for('HOSTNAME')
else
  logger.info "service issue"
  nagios_problem_type = 'service'
  nagios_problem_id = nagios_value_for('SERVICEPROBLEMID')
  nagios_state = nagios_value_for('SERVICESTATE')
  last_nagios_state = nagios_value_for('LASTSERVICESTATE', 'UNKOWN')
  nagios_notes_url = nagios_value_for('SERICENOTESURL')
  nagios_action_url = nagios_value_for('SERVICEACTIONURL')
  nagios_output = nagios_value_for('SERVICEOUTPUT')
  nagios_long_output = nagios_value_for('LONGSERVICEOUTPUT')
  nagios_service_notes = nagios_value_for('SERVICENOTES')
  issue_summary = [nagios_value_for('HOSTNAME'), nagios_value_for('SERVICEDESC')].join('/')
end

notification_type = nagios_value_for('NOTIFICATIONTYPE')
nagios_hostname = `hostname`.strip

jira_custom_field_value = "#{nagios_hostname}:#{nagios_problem_type}:#{nagios_problem_id}"

jql = "project = #{jira_project_key} AND cf[#{jira_custom_field_id}] ~ '#{jira_custom_field_value}'"

result = jira_search_issues(jql)

existing_issue = result["issues"].last
issue_body = []

issue_body << "{code}#{ENV["HOSTOUTPUT"]}{code}"
issue_body << "{code}#{nagios_long_output}{code}"
issue_body << "{code}#{nagios_service_notes}{code}"
issue_body << "*Status:* #{nagios_state}"
issue_body << "*Notes:* #{nagios_notes_url}" unless nagios_notes_url.empty?
issue_body << "*Action:* #{nagios_action_url}" unless nagios_action_url.empty?
issue_priority = priority_for_state(nagios_state, jira_warning_priority_id, jira_critical_priority_id)

# existing issue
if !existing_issue.nil?
  logger.info "existing issue: #{existing_issue["key"]}"
  if notification_type == 'PROBLEM'
    logger.info "notification_type: #{notification_type}"
    logger.info "last_nagios_state: #{last_nagios_state}"
    logger.info "nagios_state: #{nagios_state}"
    logger.info "status id: #{existing_issue["fields"]["status"]["id"]}"
    if last_nagios_state != nagios_state
      logger.info update_issue(existing_issue["key"], "priority", issue_priority)
      logger.info comment_on(existing_issue, "State changed from *#{last_nagios_state}* to *#{nagios_state}*")
      logger.info "Updated issue priority to #{issue_priority}"
    elsif existing_issue["fields"]["status"]["id"] == '6'
      logger.info "previous ticket is closed, creating a new one"
      ticket = jira_create_issue(jira_project_id, issue_summary,jira_issue_type, issue_priority,
                                 issue_body.join("\n"), jira_custom_field_id, jira_custom_field_value)
      logger.info "#{ticket["issues"][0]["key"]}"
    end

  elsif notification_type == 'RECOVERY'
    logger.info "notification_type: #{notification_type}"
    logger.info "status id: #{existing_issue["fields"]["status"]["id"]}"
    if existing_issue["status"]["id"] != '6'
      logger.info "Service recovered, closing"
      logger.info transition_to(jira_close_transition_id, existing_issue, "Service recovered\n{code}#{nagios_output}{code}")
    else
      logger.info "still warning"
      comment_on(existing_issue, "still warning")
    end
  elsif notification_type == 'ACKNOWLEDGEMENT'
    logger.info "Acknowledged, commented"
    comment_on(existing_issue,
               "Acknowledged by #{nagios_value_for('NOTIFICATIONAUTHOR')}: #{nagios_value_for('NOTIFICATIONCOMMENT')}")
  elsif notification_type == 'DOWNTIMESTART'
    logger.info "Downtime entered, commented"
    comment_on(existing_issue,
               "Entered into downtime by #{nagios_value_for('NOTIFICATIONAUTHOR')}: #{nagios_value_for('NOTIFICATIONCOMMENT')}")
  elsif notification_type == 'DOWNTIMEEND'
    logger.info "Downtime ended, commented"
    comment_on(existing_issue,
               "Downtime ended by #{nagios_value_for('NOTIFICATIONAUTHOR')}: #{nagios_value_for('NOTIFICATIONCOMMENT')}")
  elsif notification_type == 'DOWNTIMECANCELLED'
    logger.info "Downtime cancalled, commented"
    comment_on(existing_issue,
               "Downtime cancelled by #{nagios_value_for('NOTIFICATIONAUTHOR')}: #{nagios_value_for('NOTIFICATIONCOMMENT')}")
  end
  logger.info "end of if"
# new issue, don't create for anything except for new problems though
elsif notification_type == 'PROBLEM'
  logger.info "creating an issue"
  ticket = jira_create_issue(jira_project_id, issue_summary,jira_issue_type, issue_priority,
                             issue_body.join("\n"), jira_custom_field_id, jira_custom_field_value)
  logger.info "#{ticket["issues"][0]["key"]}"
else
  logger.info "no problem detected"
end
