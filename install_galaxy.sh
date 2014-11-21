#!/bin/sh -f
#
# Install and configure local Galaxy
#
. $(dirname $0)/import_functions.sh
#
# Functions
function usage() {
    # Display usage information
    cat <<EOF
Usage:

   $(basename $0) [options] DIR

Install and configure a local Galaxy instance in DIR

Options
   -h, --help     Display this help text
   --port PORT    Configure Galaxy to use PORT, rather
                  than default 8080
   --admin_users EMAIL[,EMAIL...]
                  Set one or more admin user emails
                  NB the user(s) must still be created
                  once Galaxy is running
   --release TAG  Update Galaxy code to release TAG
   --name         Name to use as the 'brand' (defaults
                  to the directory name)
   --repo URL     Specify repository to install Galaxy
                  code from (defaults to galaxy-dist
                  from bitbucket)
   --master-api-key
                  Set the master API key to a random
                  value (waring: don't use for a
                  public instance)
EOF
}
function configure_galaxy() {
    # Update the value of a parameter in the
    # universe_wsgi.ini file
    # 1: config file
    # 2: parameter
    # 3: new value
    local universe_wsgi=$1
    if [ -z "$3" ] ; then
	return
    fi
    if [ ! -f "$universe_wsgi" ] ; then
	echo ERROR
	echo No file \'$universe_wsgi\' >&2
	exit 1
    fi
    echo -n Setting \'$2\' to \'$3\' in $universe_wsgi...
    # Escape special characters in value (commas,slashes)
    local s=$(echo $3 | cut -d, -f1- --output-delimiter='\,')
    s=$(echo $s | cut -d/ -f1- --output-delimiter='\/')
    sed -i 's,#'"$2"'[ ]*=.*,'"$2"' = '"$s"',' $universe_wsgi
    if [ $? -ne 0 ] ; then
	echo FAILED
	exit 1
    else
	echo done
    fi
}
function unset_galaxy_parameter() {
    # Comment out a parameter set in universe_wsgi.ini
    # file
    # 1: parameter
    # 2: config file
    local universe_wsgi=$2
    if [ ! -f "$universe_wsgi" ] ; then
	echo ERROR
	echo No file \'$universe_wsgi\' >&2
	exit 1
    fi
    echo -n Commenting out \'$1\' in $universe_wsgi...
    sed -i 's,'"$1"' = .*,#'"$1"' = '"$s"',' $universe_wsgi
    if [ $? -ne 0 ] ; then
	echo FAILED
	exit 1
    else
	echo done
    fi
}
function report_value() {
    # Report the value of a variable, if set
    # 1: message
    # 2: value
    if [ ! -z "$2" ] ; then
	echo $1 \'$2\'
    fi
}
# Main script
GALAXY_DIR=
port=
admin_users=
galaxy_repo=https://bitbucket.org/galaxy/galaxy-dist
release_tag=
name=
use_master_api_key=
# Command line
while [ $# -ge 1 ] ; do
    case "$1" in
	--port)
	    shift
	    port=$1
	    ;;
	--admin_users)
	    shift
	    admin_users=$1
	    ;;
	--release)
	    shift
	    release_tag=$1
	    ;;
	--name)
	    shift
	    name=$1
	    ;;
	--repo)
	    shift
	    galaxy_repo=$1
	    ;;
	--master-api-key)
	    use_master_api_key=yes
	    ;;
	-h|--help)
	    usage
	    exit 0
	    ;;
	*)
	    if [ $# -eq 1 ] ; then
		GALAXY_DIR=$(full_path $1)
	    else
		echo "Unrecognised argument: $1" >&2
		exit 1
	    fi
	    ;;
    esac
    shift
done
if [ -z "$GALAXY_DIR" ] ; then
  echo ERROR no directory specified >&2
  exit 1
elif [ -e $GALAXY_DIR ] ; then
  echo ERROR $GALAXY_DIR: directory already exists >&2
  exit 1
fi
if [ -z "$name" ] ; then
    name=$(basename $GALAXY_DIR)
fi
echo "###################################################"
echo "### Install and configure local Galaxy instance ###"
echo "###################################################"
# Settings
report_value "Install new Galaxy instance in" $GALAXY_DIR
report_value "Install code from" $galaxy_repo
report_value "Set name to" $name
report_value "Set port to" $port
report_value "Set admin users to" $admin_users
report_value "Set release tag to" $release_tag
# Check prerequisites
check_program python
check_program virtualenv
check_program hg
check_program pwgen
check_program R
check_program samtools
# Set up install log
LOG_FILE=$(pwd)/install.galaxy.$(basename $GALAXY_DIR).log
clean_up_file $LOG_FILE
# Start
create_directory $GALAXY_DIR
cd $GALAXY_DIR
# Create and activate a Python virtualenv for this instance
create_virtualenv galaxy_venv
activate_virtualenv galaxy_venv
# Install NumPy
pip_install galaxy_venv/bin numpy
# Install bioblend
pip_install galaxy_venv/bin bioblend
# Fetch Galaxy code
hg_clone $galaxy_repo
galaxy_src=$(basename $galaxy_repo)
cd $galaxy_src
run_command --log $LOG_FILE "Switching to Galaxy stable branch" hg update stable
if [ ! -z "$release_tag" ] ; then
    echo -n Checking that tag \"$release_tag\" exists...
    got_release_tag=$(hg tags | grep -w "^$release_tag")
    if [ -z "$got_release_tag" ] ; then
	echo not found
	echo ERROR no tag \"$release_tag\" >&2
	exit 1
    else
	echo yes
    fi
    run_command --log $LOG_FILE "Pulling in all updates" hg pull
    run_command --log $LOG_FILE "Switching to release tag $release_tag" hg update $release_tag
fi
# Create custom universe_wsgi.ini file
if [ -f universe_wsgi.ini.sample ] ; then
    run_command "Creating universe_wsgi.ini file" cp universe_wsgi.ini.sample universe_wsgi.ini
    export CONFIG_FILE=universe_wsgi.ini
elif [ -f config/galaxy.ini.sample ] ; then
    run_command "Creating config/galaxy.ini file" cp config/galaxy.ini.sample config/galaxy.ini
    export CONFIG_FILE=config/galaxy.ini
fi  
echo Configuring settings in $CONFIG_FILE
configure_galaxy $CONFIG_FILE id_secret $(pwgen 8 1)
configure_galaxy $CONFIG_FILE port $port
configure_galaxy $CONFIG_FILE admin_users $admin_users
configure_galaxy $CONFIG_FILE brand $name
configure_galaxy $CONFIG_FILE tool_config_file "tool_conf.xml,shed_tool_conf.xml,local_tool_conf.xml"
configure_galaxy $CONFIG_FILE allow_library_path_paste True
configure_galaxy $CONFIG_FILE tool_dependency_dir "../tool_dependencies"
# Set the master API key for bootstrapping
if [ ! -z "$use_master_api_key" ] ; then
    master_api_key=$(pwgen 16 1)
    configure_galaxy $CONFIG_FILE master_api_key $master_api_key
fi
# Initialise: fetch eggs, copy sample file, create database etc
if [ -f scripts/common_startup.sh ] ; then
    run_command --log $LOG_FILE "Initialising eggs and sample files" \
	scripts/common_startup.sh
else
    run_command --log $LOG_FILE "Fetching python eggs" \
	python scripts/fetch_eggs.py
    run_command --log $LOG_FILE "Copying sample files" \
	scripts/copy_sample_files.sh
fi
run_command --log $LOG_FILE "Creating the database" python scripts/create_db.py
run_command --log $LOG_FILE "Migrating tools" sh manage_tools.sh upgrade
cd ..
# Create directories for local and shed tools
echo Creating supporting directories
create_directory local_tools
create_directory shed_tools
create_directory tool_dependencies
# Make conf file for local tools
echo -n Creating empty local_tool_conf.xml file...
cat > $galaxy_src/local_tool_conf.xml <<EOF
<?xml version="1.0"?>
<toolbox tool_path="../local_tools">
<label id="local_tools" text="Local Tools" />
  <!-- Example of section and tool definitions -->
  <section id="example_tools" name="Local Tools">
  	<!--Add tool references here-->
  </section>
</toolbox>
EOF
echo done
# 
# Create wrapper script to run galaxy
echo -n Making wrapper script \'run_galaxy.sh\'...
cat > run_galaxy.sh <<EOF
#!/bin/sh
# Automatically generated script to run galaxy in $(basename $GALAXY_DIR)
# Galaxy code from $galaxy_repo
GALAXY_DIR=\$(dirname \$0)
if [ -z \$(echo \$GALAXY_DIR | grep "^/") ] ; then
  GALAXY_DIR=\$(pwd)/\$GALAXY_DIR
fi
echo -n "Running Galaxy from \$GALAXY_DIR"
if [ ! -z "\$@" ] ; then
  echo " using options: \$@"
else
  echo
fi
# Activate virtualenv
. \$GALAXY_DIR/galaxy_venv/bin/activate
# Run Galaxy with the specified options
cd \$GALAXY_DIR/$galaxy_src
sh run.sh \$@ 2>&1
##
#
EOF
chmod +x run_galaxy.sh
echo done
# Finished
deactivate
echo "Finished installing Galaxy in $GALAXY_DIR"
##
#
