# ABSTRACT: Simple way to create applications

=head1 NAME

 App::Basis

=head1 SYNOPSIS

    use App::Basis

    # main
    my %opt = App::Basis::init_app(
    help_text   => 'Sample program description'
    , help_cmdline => 'extra stuff to print about command line use'
    , options   =>  {
        'file|f=s'  => {
            desc => 'local system location of xml data'
            , required => 1
        } 
        , 'url|u=s' => {
            desc => 'where to find xml data on the internet'
            , validate => sub { my $url = shift ; return $url =~ m{^(http|file|ftp)://} ; }
        }
        , 'keep|k'  => {
            # no point in having this if there is no file option
            desc => 'keep the local file, do not rename it'
            , depends => 'file'
        }
        , 'counter|c=i' => {
            desc => 'check a counter'
            , default   => 5
        }
        , 'basic'   => 'basic argument, needs no hashref data'
    }
    , ctrl_c   => \&ctrl_c_handler  # override built in ctrl-c handler
    , cleanup  => \&cleanup_func    # optional func to call to clean up
    , debug    => \&debug_func      # optional func to call with debugging data
    ) ;

    show_usage("need keep option") if( !$opt{keep}) ;

    msg_exit( "spurious reason to exit with error code 3", 3) ;

=head1 DESCRIPTION

There are a number of ways to help script development and to encorage people to do the right thing.
One of thses is to make it easy to get parameters from the command line. Obviously you can play with Getopt::Long and
continuously write the same code and add in your own handlers for help etc, but then your co-workers and friends
make not be so consistent, leading to scripts that have no help and take lots of cryptic parameters.

So I created this module to help with command line arguments and displaying help, then I added L<App::Basis::Config> because
everyone needs config files and does not want to constantly repeat themselves there either.

So how is better than other similar modules? I can't say that it is, but it meets my needs.

There is app help available, there is basic debug functionality, which you can extend using your own function, 
you can daemonise your script or run a shell command and get the output/stderr/return code.

If you choose to use App::Basis::Config then you will find easy methods to manage reading/saving YAML based config data.

There are (or will be) other App::Basis modules available to help you write scripts without you having to do complex things
or write lots of code.

=cut

package App::Basis;

use 5.014;
use warnings;
use strict;
use File::Basename qw(basename dirname);
use Getopt::Long;
use Exporter;
use File::Temp qw( tempfile);
use IPC::Cmd qw(run run_forked);
use List::Util qw(max);

use vars qw( @EXPORT @ISA);

@ISA = qw(Exporter);

# this is the list of things that will get imported into the loading packages
# namespace
@EXPORT = qw(
    init_app
    show_usage
    msg_exit
    get_program
    debug set_debug
    daemonise
    execute_cmd run_cmd
    fix_filename
    set_test_mode
);

# ----------------------------------------------------------------------------

my $PROGRAM = basename $0 ;

# these variables are held available throughout the life of the app
my $_app_simple_ctrlc_count = 0;
my $_app_simple_ctrlc_handler;
my $_app_simple_help_text    = 'Application has not defined help_text yet.';
my $_app_simple_help_options = '';
my $_app_simple_cleanup_func;
my $_app_simple_help_cmdline = '';

my %_app_simple_objects = ();
my %_cmd_line_options   = ();

# we may want to die rather than exiting, helps with testing!
my $_test_mode = 0;

=head1 Public Functions

=over 4

=cut

# ----------------------------------------------------------------------------
# control how we output things to help with testing
sub _output {
    my ( $where, $msg ) = @_;

    if ( !$_test_mode ) {
        if ( $where =~ /stderr/i ) {
            say STDERR $msg;
        }
        else {
            say $msg ;
        }
    }
}

# ----------------------------------------------------------------------------

=item debug

Write some debug data. If a debug function was passed to init_app that will be 
used, otherwise we will write to STDERR.

    debug( "WARN", "some message") ;
    debug( "ERROR", "Something went wrong") ;

B<Parameters>
  string used as a 'level' of the error
  array of anything else, normally error description strings

If your script uses App::Basis make sure your modules do too, then any debug 
can go to your default debug handler, like log4perl, but simpler!

=cut

sub debug {
    my ( $level, @debug ) = @_;

    # we may want to undef the debug object, so no debug comes out

    if ( exists $_app_simple_objects{logger} ) {

        # run the coderef for the logger
        $_app_simple_objects{logger}->( $level, @debug ) if ( defined $_app_simple_objects{logger} );
    }
    else {
        # write all the debug lines to STDERR
        _output( 'STDERR', "$level: " . join( ' ', @debug ) );
    }
}

# ----------------------------------------------------------------------------

=item set_debug

Tell App:Simple to use a different function for the debug calls. 
Generally you don't need this if you are using init_app, add the link there.

B<Parameters>
  coderef pointing to the function you want to do the debugging

=cut

sub set_debug {
    my $func = shift;
    if ( !$func || ref($func) ne "CODE" ) {
        debug( "WARN", "set_debug function expects a CODE, got a " . ref( ($func) ) );
    }
    else {
        $_app_simple_objects{logger} = $func;
    }
}

# ----------------------------------------------------------------------------

=item init_app

B<Parameters> hash of these things

    help_text    - what to say when people do app --help
    help_cmdline - extra things to put after the sample args on a sample command line (optional)
    cleanup      - coderef of function to call when your script ends (optional)
    debug        - coderef of function to call to save/output debug data (optional, recommended)
    ctrlc_func   - coderef of function to call when user presses ctrl-C
    options      - hashref of program arguments
      simple way
      'fred'     => 'some description of fred'
      'fred|f'   => 'fred again, also allows -f as a variant'
      'fred|f=s' => 'fred needs to be a string'
      'fred|f=i' => 'fred needs to be an integer'

      complex way, more features, validation, dependancies etc
      'fred|f=s' => {
         desc      => 'description of argument',
         # check if fred is one of the allowed things
         validate  => sub { my $fred = shift ; $fred =~ m/bill|mary|jane|sam/i ;},
         # does this option need another option to exist
         depends   => 'otheroption'
       }
      'fred|f=s' => {
         desc     => 'description of argument',
         default  => 'default value for fred'
      }

B<Note will die if not passed a HASH of arguments>

=cut

sub init_app {
    my %args = @_ % 2 ? die("Odd number of values passed where even is expected.") : @_;
    my @options;
    my $has_required = 0;
    my %full_options;

    if ( $args{debug} ) {
        set_debug( $args{debug} );
    }

    # get program description
    $_app_simple_help_text    = $args{help_text}    if ( $args{help_text} );
    $_app_simple_help_cmdline = $args{help_cmdline} if ( $args{help_cmdline} );

    die "options must be a hashref" if ( ref( $args{options} ) ne 'HASH' );

    $args{options}->{'help|h|?'} = 'Show help';

    my @keys         = sort keys %{ $args{options} };
    my %dnames       = _desc_names(@keys);
    my $max_desc_len = max( map length, values %dnames ) + 1;
    my $help_fmt     = "    %-${max_desc_len}s    %s\n";

    # add help text for 'help' first.
    $_app_simple_help_options .= sprintf $help_fmt, $dnames{'help|h|?'}, 'Show help';

    # get options and their descriptions
    # foreach my $o ( sort keys %{ $args{options} } ) {
    foreach my $o (@keys) {

        # save the option
        push @options, $o;

        my $name = $o;

        # we want the long version of the name if its provided
        $name =~ s/.*?(\w+).*/$1/;

        # remove any type data
        $name =~ s/=(.*)//;

        if ( ref( $args{options}->{$o} ) eq 'HASH' ) {
            die "parameterised option '$name' require a desc option"
                if ( !$args{options}->{$o}->{desc} );
            $full_options{$name} = $args{options}->{$o};
            $has_required++ if ( $full_options{$name}->{required} );
        }
        else {
            $full_options{$name} = {
                desc => $args{options}->{$o},

                # possible options that can be passed
                # depends => '',
                # default => '',
                # required => 0,
                # validate => sub {}
            };
        }

        # save the option string too
        $full_options{$name}->{options} = $o;

        # build the entry for the help text
        my $desc = $full_options{$name}->{desc};
        if ( $name ne 'help' ) {
            my $desc = $full_options{$name}->{desc};

            # # show the right way to use the options, single chars get - prefix
            # # names get -- prefix
            # my $dname = $name;
            # $dname .= '*' if ( $full_options{$name}->{required} );
            # $dname = ( length($dname) > 1 ? '--' : '-' ) . $dname;
            # my $sep = 15 - length($dname);
            # $sep = 0 if ( $sep < 0 );
            # $desc .= " [DEFAULT: $full_options{$name}->{default}]"
            #     if ( $full_options{$name}->{default} );
            # $_app_simple_help_options .= "    $dname" . ( ' ' x $sep ) . " $desc\n";

            # show the right way to use the options
            my $dname = $dnames{$o};
            $dname .= '*' if ( $full_options{$name}->{required} );

            $desc .= " [DEFAULT: $full_options{$name}->{default}]" if ( $full_options{$name}->{default} );
            $_app_simple_help_options .= sprintf $help_fmt, $dname, $desc;
        }

    }

    # show required options
    if ($has_required) {
        $_app_simple_help_options .= "* required option" . ( $has_required > 1 ? 's' : '' ) . "\n";
    }

    # catch control-c, user provided or our default
    $_app_simple_ctrlc_handler = $args{ctrl_c} ? $args{ctrl_c} : \&_app_simple_ctrlc_func;
    $SIG{'INT'} = $_app_simple_ctrlc_handler;

    # get an cleanup function handler
    $_app_simple_cleanup_func = $args{cleanup} if ( $args{cleanup} );

    # check command line args
    GetOptions( \%_cmd_line_options, @options );

    # help is a built in
    show_usage() if ( $_cmd_line_options{help} );

    # now if we have the extended version we can do some checking
    foreach my $name ( sort keys %full_options ) {
        warn "Missing desc field for $name" if ( !$full_options{$name}->{desc} );
        if ( $full_options{$name}->{required} ) {
            show_usage( "Required option '$name' is missing", 1 ) if ( !( $_cmd_line_options{$name} || $full_options{$name}->{default} ) );
        }
        if ( $full_options{$name}->{depends} ) {
            if ( !$_cmd_line_options{ $full_options{$name}->{depends} } ) {
                show_usage( "Option '$name' depends on option '$full_options{$name}->{depends}' but it is missing", 1 );
            }
        }

        # set a default if there is no value
        if ( $full_options{$name}->{default} ) {
            $_cmd_line_options{$name} = $full_options{$name}->{default} if ( !$_cmd_line_options{$name} );
        }

        # call the validation routine if we have one
        if ( $full_options{$name}->{validate} ) {
            die "need to pass a coderef to validate for option '$name'" if ( !ref( $full_options{$name}->{validate} ) eq 'CODE' );
            die "Option '$name' has validate and should either also have a default or be required"
                if ( !( $full_options{$name}->{required} || $full_options{$name}->{default} ) );
            my $coderef = $full_options{$name}->{validate};
            my $result  = $coderef->( $_cmd_line_options{$name} );
            show_usage("Option '$name' does not pass validation") if ( !$result );
        }
    }

    return %_cmd_line_options;
}

# ----------------------------------------------------------------------------

=item get_program

get the name of the running program
just a helper function

=cut

sub get_program {
    return $PROGRAM;
}

# ----------------------------------------------------------------------------

=item get_options

return the command line options hash
just a helper function

=cut 

sub get_options {
    return %_cmd_line_options;
}

# ----------------------------------------------------------------------------
# handle the ctrl-c presses

sub _app_simple_ctrlc_func {

    # exit if we are already in ctrlC
    exit(2) if ( $_app_simple_ctrlc_count++ );
    _output( 'STDERR', "\nCaught Ctrl-C. press again to exit immediately" );

    # re-init the handler
    $SIG{'INT'} = $_app_simple_ctrlc_handler;
}

# ----------------------------------------------------------------------------

# to help with testing we may want to die, which can be caught rather than
# exiting, so lets find out

sub _exit_or_die {
    my $state = shift || 1;

    if ($_test_mode) {
        STDERR->flush();
        STDOUT->flush();
        die "exit state $state";
    }
    exit($state);
}

# ----------------------------------------------------------------------------

=item show_usage

show how this program is used, outputs help, parameters etc, this is written
to STDERR

B<Parameters>
  msg     - additional message to explain why help is displayed (optional)
  state   - int value to exit the program with

B<Sample output help>
    Syntax: app [options] other things

    About:  Boiler plate code for an App::Basis app

    [options]
        --help          Show help
        --item          another item [DEFAULT: 123]
        --test          test item [DEFAULT: testing 123]
        --verbose       Dump extra useful information

=cut

sub show_usage {
    my ( $msg, $state ) = @_;

    my $help = qq{
Syntax: $PROGRAM [options] $_app_simple_help_cmdline

About:  $_app_simple_help_text

[options]
$_app_simple_help_options};
    if ($msg) {

        # if we have an error message it MUST go to STDERR
        # to make sure that any program the output is piped to
        # does not get the message to process
        _output( 'STDERR', "$help\nError: $msg\n" );
    }
    else {
        _output( 'STDOUT', $help );
    }

    _exit_or_die($state);
}

# ----------------------------------------------------------------------------

=item msg_exit

Exit this program writting a message to to STDERR

B<Parameters>
  msg     - message to explain what is going on
  state   - int value to exit the program with

=cut

sub msg_exit {
    my ( $msg, $state ) = @_;

    _output( 'STDERR', $msg ) if ($msg);
    _exit_or_die($state);
}

# -----------------------------------------------------------------------------

=item daemonise

create a daemon process, detach from the controlling tty
if called by root user, we can optionally specify a dir to chroot into to keep things safer

B<Parameters>
    rootdir - dir to root the daemon into  (optional, root user only)

B<Note: will die on errors>

=cut

sub daemonise {
    my $rootdir = shift;

    if ($rootdir) {
        chroot($rootdir)
            or die "Could not chroot to $rootdir, only the root user can do this.";
    }

    # fork once and let the parent exit
    my $pid = fork();

    # exit if $pid ;
    # parent to return 0, as it is logical
    if ($pid) {
        return 0;
    }
    die "Couldn't fork: $!" unless defined $pid;

    # disassociate from controlling terminal, leave the
    # process group behind

    POSIX::setsid() or die "Can't start a new session";

    # show that we have started a daemon process
    return 1;
}

# ----------------------------------------------------------------------------

=item execute_cmd

 execute_cmd(command => ['/my/command','--args'], timeout => 10);

Executes a command using IPC::Cmd::run_forked, less restrictive than run_cmd
see L<IPC::Cmd> for more options that 

Input hashref

    command         - string to execute (arrayrefs aren't supported, for some reason)
    timeout         - timeout (in seconds) before command is killed
    stdout_handler  - see IPC::Cmd docs
    stderr_handler  - see IPC::Cmd docs
    child_stdin     - pass data to STDIN of forked processes
    discard_output  - don't return output in hash
    terminate_on_parent_sudden_death

Output HASHREF

    exit_code       - exit code
    timeout         - time taken to timeout or 0 if timeout not used
    stdout          - text written to STDOUT
    stderr          - text written to STDERR
    merged          - stdout and stderr merged into one stream
    err_msg         - description of any error that occurred.

=cut

sub execute_cmd {
    my %args = @_;
    my $command = $args{command} or die "command required";

    my $r = IPC::Cmd::run_forked( $command, \%args );

    return $r;
}

# ----------------------------------------------------------------------------

=item run_cmd

Basic way to run a shell program and get its output, this is not interactive.
For interactiviness see execute_cmd.

By default if you do not pass a full path to the command, then unless the command
is in /bin, /usr/bin, /usr/local/bin then the command will not run.

my ($code, $out, $err) = run_cmd( 'ls') ;
#
($code, $out, $err) = run_cmd( 'ls -R /tmp') ;

B<Parameters>
  string to run in the shell

=cut

sub run_cmd {
    my $cmd = shift;

    # use our path and not the system one so that it can pass taint checks
    local $ENV{PATH} = "/bin:/usr/bin:/usr/local/bin:$ENV{HOME}/bin";

    my ( $ret, $err, $full_buff, $stdout_buff, $stderr_buff ) = run( command => $cmd );

    # my $full = join( "\n", @{$full_buff}) ;
    my $stdout = join( "\n", @{$stdout_buff} );
    my $stderr = join( "\n", @{$stderr_buff} );

    return ( !$ret, $stdout, $stderr );
}

# -----------------------------------------------------------------------------

=item fix_filename

Simple way to replace ~, ./ and ../ at the start of filenames

B<Parameters>
  file name that needs fixing up

=cut

sub fix_filename {
    my $file = shift;

    $file =~ s/^~/$ENV{HOME}/;
    if ( $file =~ m|^\.\./| ) {
        my $parent = dirname( $ENV{PWD} );
        $file =~ s|^(\.\.)/|$parent/|;
    }
    if ( $file =~ m|^\./| || $file eq '.' ) {
        $file =~ s|^(\.)/?|$ENV{PWD}|;
    }
    return $file;
}

# ----------------------------------------------------------------------------
# Returns a hash containing a formatted name for each option. For example:
# ( 'help|h|?' ) -> { 'help|h|?' => '-h, -?, --help' }
sub _desc_names {
    my %descs;
    foreach my $o (@_) {
        $_ = $o;    # Keep a copy of key in $o.
        s/=.*$//;

        # Sort by length so single letter options are shown first.
        my @parts = sort { length $a <=> length $b } split /\|/;

        # Single chars get - prefix, names get -- prefix.
        my $s = join ", ", map { ( length > 1 ? '--' : '-' ) . $_ } @parts;

        $descs{$o} = $s;
    }
    return %descs;
}

# ----------------------------------------------------------------------------
# special function to help us test this module, as it flags that we can die
# rather than exiting when doing some operations
# also test mode will not output to STDERR/STDOUT

sub set_test_mode {
    $_test_mode = shift;
}

# ----------------------------------------------------------------------------
# make sure we do any cleanup required

END {

    # call any user supplied cleanup
    if ($_app_simple_cleanup_func) {
        $_app_simple_cleanup_func->();
        $_app_simple_cleanup_func = undef;
    }
}

=back

=cut

# ----------------------------------------------------------------------------

1;
