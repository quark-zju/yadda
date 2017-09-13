@stylesheet = """
.yadda .aphront-table-view td { padding: 3px 4px; }
.yadda table { table-layout: fixed; }
.yadda thead { cursor: default; }
.yadda code, .yadda kbd { background: #EBECEE; padding: 0px 4px; margin: 0px 2px; border-radius: 3px; }
.yadda td input { display: inline-block; vertical-align: middle; margin: 3px 5px; }
.yadda td.selected, .yadda td.not-selected { padding: 0px 2px; }
.yadda td.selected { background: #3498db; }
.yadda td.size { text-align: right; }
.yadda tbody { border-bottom: 1px solid #D0E0ED; }
.yadda tbody:last-child { border-bottom: transparent; }
.yadda .profile { width: 20px; height: 20px; display: inline-block; vertical-align: middle; background-size: cover; background-position: center top; background-repeat: no-repeat; background-clip: content-box; border-radius: 2px; }
.yadda .profile.action { margin: 1px; float: left; }
.yadda .profile.action.read { opacity: 0.4; }
.yadda .profile.action.read.shrink { width: 11px; border-bottom-right-radius: 0; border-top-right-radius: 0; margin-left: 0; margin-right: 0; box-shadow: inset -1px 0px 0px 0px rgba(255,255,255,0.5); }
.yadda .profile.action.read.shrink:nth-child(n+2) { border-bottom-left-radius: 0; border-top-left-radius: 0; }
.yadda .profile.sensible-action { height: 15px; padding-bottom: 1px; border-bottom-right-radius: 0; border-bottom-left-radius: 0; border-bottom-width: 4px; border-bottom-style: solid; }
.yadda .profile.sensible-action.series { height: 13px; border-bottom-width: 6px; }
.yadda .profile.accept { border-bottom-color: #139543; }
.yadda .profile.reject { border-bottom-color: #C0392B; }
.yadda .profile.update { border-bottom-color: #3498DB; }
.yadda .profile.request-review { border-bottom: 4px solid #6e5cb6; }
.yadda td.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.yadda tr.read.muted { background: #f8e9e8; }
.yadda tr.passive-appear, .yadda tr.passive-appear:hover { background-color: #EFF1F7; }
.yadda tr.passive-appear td.title, .yadda tr.passive-appear td.time, .yadda tr.passive-appear td.size { opacity: 0.6; }
.yadda tr.selected, .yadda tr.selected:hover { background-color: #FDF3DA; }
.yadda .table-bottom-info { margin-top: 12px; margin-left: 8px; display: block; color: #74777D; }
.yadda .phab-status.accepted { color: #139543 }
.yadda .phab-status.needs-revision { color: #c0392b }
.yadda .action-selector { border: 0; border-radius: 0; }
.yadda .action-selector:focus { outline: none; }
.yadda .yadda-content { margin-bottom: 16px }
.yadda .config-item { margin-bottom: 20px; }
.yadda .config-desc { margin-left: 160px; margin-bottom: 8px;}
.yadda .config-oneline-pair { display: flex; align-items: baseline; }
.yadda .config-name { width: 146px; font-weight: bold; color: #6B748C; text-align: right; margin-right: 16px; }
.yadda .action-selector.embedded { float: right; padding: 0; background-color: transparent; height: 100%; color: black; }
.yadda .action-selector.mobile {  position: fixed; bottom: 0; width: 100%; border-top: 1px solid #C7CCD9; z-index: 10; }
.got-it { margin-top: 8px; margin-right: 12px; display: block; float: right; }
.device-desktop .action-selector.mobile { display: none; }
.device-tablet .action-selector.mobile { display: none; }
.device-phone .action-selector.embed { display: none; }
.device-desktop .yadda-content { margin: 16px; }
.device-desktop th.actions { width: 30%; }
.device-tablet th.actions { width: 35%; }
.device-tablet th.size, .device-tablet td.size { display: none; }
.device-tablet .yadda table, .device-phone .yadda table { border-left: none; border-right: none; }
.device-phone thead, .device-phone td.time, .device-phone td.size { display: none; }
.device-phone td.selector-indicator { display: none; }
.device-phone td.author { display: none; }
.device-phone td.title { float: left; font-size: 1.2em; max-width: 100%; }
.device-phone td.phab-status { display: none; }
.device-phone td.actions { float: right; }
.device-phone td.checkbox { display: none; }
.device-phone .table-bottom-info { margin-bottom: 30px; }
.device-phone .yadda .config-oneline-pair { flex-wrap: wrap; }
.device-phone .yadda .config-desc { margin-left: 0; }
.device-phone .yadda .config-name { width: 100%; text-align: left; }
"""
