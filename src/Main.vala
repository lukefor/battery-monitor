/*
 * Main.vala
 *
 * Copyright 2015 Tony George <teejee2008@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */

using GLib;
using Gtk;
using Gee;
using Json;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JSON;
using TeeJee.ProcessManagement;
using TeeJee.GtkHelper;
using TeeJee.Multimedia;
using TeeJee.System;
using TeeJee.Misc;

public Main App;
public const string AppName = "Aptik Battery Monitor";
public const string AppShortName = "aptik-bmon";
public const string AppVersion = "1.0.2";
public const string AppAuthor = "Tony George";
public const string AppAuthorEmail = "teejeetech@gmail.com";

const string GETTEXT_PACKAGE = "";
const string LOCALE_DIR = "/usr/share/locale";

extern void exit(int exit_code);

public class Main : GLib.Object{
	public static string BATT_STATS_CACHE_FILE = "/var/log/aptik-bmon/stats.log";
	public static string RC_LOCAL_FILE = "/etc/rc.local";
	public static string RC_BMON_LINE = "/usr/bin/aptik-bmon &";
	public static int BATT_STATS_LOG_INTERVAL = 30;
	public static double BATT_STATS_ARCHIVE_LEVEL = 99.00;

	public bool gui_mode = false;
	public string user_login = "";
	public string user_home = "";
	public int user_uid = -1;

	public string temp_dir = "";
	public string backup_dir = "";
	public string share_dir = "/usr/share";
	public string app_conf_path = "";

	public Gee.ArrayList<BatteryStat> battery_stats_list;
	public BatteryStat stat_prev;

	public Main(string[] args, bool _gui_mode){

		gui_mode = _gui_mode;

		//config file
		string home = Environment.get_home_dir();
		app_conf_path = home + "/.config/aptik-bmon.json";

		//load settings if GUI mode
		if (gui_mode){
			load_app_config();
		}

		//check dependencies
		string message;
		if (!check_dependencies(out message)){
			if (gui_mode){
				string title = _("Missing Dependencies");
				gtk_messagebox(title, message, null, true);
			}
			exit(0);
		}

		//initialize backup_dir as current directory for CLI mode
		if (!gui_mode){
			backup_dir = Environment.get_current_dir() + "/";
		}

		try{
			//create temp dir
			temp_dir = get_temp_file_path();

			var f = File.new_for_path(temp_dir);
			if (f.query_exists()){
				Posix.system("rm -rf %s".printf(temp_dir));
			}
			f.make_directory_with_parents();
		}
		catch (Error e) {
			log_error (e.message);
		}

		//get user info
		user_login = get_user_login();
		user_home = "/home/" + user_login;
		user_uid = get_user_id(user_login);
	}

	public bool check_dependencies(out string msg){
		msg = "";

		string[] dependencies = { "grep","find" };

		string path;
		foreach(string cmd_tool in dependencies){
			path = get_cmd_path (cmd_tool);
			if ((path == null) || (path.length == 0)){
				msg += " * " + cmd_tool + "\n";
			}
		}

		if (msg.length > 0){
			msg = _("Commands listed below are not available on this system") + ":\n\n" + msg + "\n";
			msg += _("Please install required packages and try running Aptik again");
			log_msg(msg);
			return false;
		}
		else{
			return true;
		}
	}

	/* Common */

	public string create_log_dir(){
		string log_dir = backup_dir + "logs/" + timestamp3();
		create_dir(log_dir);
		return log_dir;
	}

	public void save_app_config(){
		var config = new Json.Object();

		var json = new Json.Generator();
		json.pretty = true;
		json.indent = 2;
		var node = new Json.Node(NodeType.OBJECT);
		node.set_object(config);
		json.set_root(node);

		try{
			json.to_file(this.app_conf_path);
		} catch (Error e) {
	        log_error (e.message);
	    }

	    if (gui_mode){
			log_msg(_("App config saved") + ": '%s'".printf(app_conf_path));
		}
	}

	public void load_app_config(){
		var f = File.new_for_path(app_conf_path);
		if (!f.query_exists()) { return; }

		var parser = new Json.Parser();
		try{
			parser.load_from_file(this.app_conf_path);
		}
		catch (Error e) {
		  log_error (e.message);
		}

		//var node = parser.get_root();
		//var config = node.get_object();

		if (gui_mode){
			log_msg(_("App config loaded") + ": '%s'".printf(this.app_conf_path));
		}
	}

	public void exit_app(){

		save_app_config();

		try{
			//delete temporary files
			var f = File.new_for_path(temp_dir);
			if (f.query_exists()){
				f.delete();
			}
		}
		catch (Error e) {
			log_error (e.message);
		}
	}

	/* Battery Stats */

	public void log_battery_stats(bool print_stats){
		try {
			var file = File.new_for_path(BATT_STATS_CACHE_FILE);
			if (!file.query_exists()){
				create_empty_log_file();
			}

			var fos = file.append_to (FileCreateFlags.NONE);
			var dos = new DataOutputStream (fos);
			var stat = new BatteryStat.read_from_sys();
			dos.put_string(stat.to_delimited_string());
			if (print_stats){
				stdout.printf(stat.to_delimited_string());
			}

			// Archive log file at 100% battery ----------------------

			if (stat_prev != null){
				if ((stat_prev.charge_percent() >= BATT_STATS_ARCHIVE_LEVEL)
				&& (stat.charge_percent() < BATT_STATS_ARCHIVE_LEVEL)){

					var date_label = (new DateTime.now_local()).format("%F_%H-%M-%S");
					var archive = File.new_for_path(BATT_STATS_CACHE_FILE + "." + date_label);
					file.move(archive,FileCopyFlags.NONE);
					create_empty_log_file();
				}
			}

			stat_prev = stat;
		}
		catch (Error e){
			log_error (e.message);
		}
	}

	private void create_empty_log_file(){
		try {
			var file = File.new_for_path(BATT_STATS_CACHE_FILE);
			var parent_dir = file.get_parent();

			if(!parent_dir.query_exists()){
				parent_dir.make_directory_with_parents();
				Posix.system("chmod a+rwx '%s'".printf(parent_dir.get_path()));
			}

			if(!file.query_exists()){
				Posix.system("touch '%s'".printf(file.get_path()));
				Posix.system("chmod a+rwx '%s'".printf(file.get_path()));
			}
		}
		catch (Error e){
			log_error (e.message);
		}
	}

	public void read_battery_stats(){
		log_debug("call: read_battery_stats");
		var timer = timer_start();

		try{
			battery_stats_list = new Gee.ArrayList<BatteryStat>();

			var file = File.new_for_path (BATT_STATS_CACHE_FILE);
			if (file.query_exists ()) {
				var dis = new DataInputStream (file.read());

				string line;
				while ((line = dis.read_line (null)) != null) {
					var stat = new BatteryStat.from_delimited_string(line);
					battery_stats_list.add(stat);
				}

				/*CompareDataFunc<string> func = (a, b) => {
					return strcmp(a,b);
				};
				sections.sort((owned)func);*/

				log_debug("read_battery_stats: %s".printf(timer_elapsed_string(timer)));
			}
			else{
				log_error ("File not found: %s".printf(BATT_STATS_CACHE_FILE));
			}
		}
		catch (Error e){
			log_error (e.message);
		}
	}

	public bool is_logging_enabled(){
		bool enabled = false;

		try{
			var file = File.new_for_path (RC_LOCAL_FILE);
			if (file.query_exists ()) {
				var dis = new DataInputStream (file.read());

				string line;
				while ((line = dis.read_line (null)) != null) {
					if (line.contains("aptik-bmon")){
						enabled = true;
						break;
					}
				}
			}
			else{
				log_error ("File not found: %s".printf(RC_LOCAL_FILE));
			}
		}
		catch (Error e){
			log_error (e.message);
		}

		return enabled;
	}

	public void set_battery_monitoring_status(bool enabled){
		if (enabled){

			if (is_logging_enabled()){ return; }

			try{
				/*var file = File.new_for_path (RC_LOCAL_FILE);
				if (!file.query_exists ()) {
					log_error ("File not found: %s".printf(RC_LOCAL_FILE));
					return;
				}*/

				if (!file_exists(RC_LOCAL_FILE)) {
					log_error ("File not found: %s".printf(RC_LOCAL_FILE));
					return;
				}

				var txt = read_file(RC_LOCAL_FILE);
				var lines = new Gee.ArrayList<string>();
				foreach (string line in txt.split("\n")) {
					lines.add(line);
				}

				Regex rex_exit_line = new Regex("""^[ \t]*exit[ \t\(]*0[ \t\)]*$""");
				MatchInfo match;

				for(int i = 0; i < lines.size; i++){
					string line = lines[i];
					if (rex_exit_line.match (line, 0, out match)){
						lines.insert(i, RC_BMON_LINE);
						break;
					}
				}

				txt = "";
				for(int i = 0; i < lines.size; i++){
					string line = lines[i];
					bool is_last_line = (i == lines.size - 1);
					if ((line.length == 0) && is_last_line){ continue; }
					txt += line + "\n";
				}
				write_file(RC_LOCAL_FILE,txt);
				Posix.system("chmod a+x %s".printf(RC_LOCAL_FILE));

				if (!process_is_running_by_name(AppShortName)){
					execute_command_script_async(RC_BMON_LINE);
				}
			}
			catch (Error e){
				log_error (e.message);
			}
		}
		else{
			if (!is_logging_enabled()){ return; }

			try{
				if (!file_exists(RC_LOCAL_FILE)) {
					log_error ("File not found: %s".printf(RC_LOCAL_FILE));
					return;
				}

				var txt = read_file(RC_LOCAL_FILE);
				var lines = new Gee.ArrayList<string>();
				foreach (string line in txt.split("\n")) {
					lines.add(line);
				}

				for(int i = 0; i < lines.size; i++){
					string line = lines[i];
					if (line == RC_BMON_LINE){
						lines.remove(line);
						break;
					}
				}

				txt = "";
				for(int i = 0; i < lines.size; i++){
					string line = lines[i];
					bool is_last_line = (i == lines.size - 1);
					if ((line.length == 0) && is_last_line){ continue; }
					txt += line + "\n";
				}
				write_file(RC_LOCAL_FILE,txt);
				Posix.system("chmod a+x %s".printf(RC_LOCAL_FILE));

				if (process_is_running_by_name(AppShortName)){
					command_kill(AppShortName,AppShortName);
				}
			}
			catch (Error e){
				log_error (e.message);
			}
		}
	}
}
