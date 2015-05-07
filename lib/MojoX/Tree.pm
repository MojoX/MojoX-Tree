package MojoX::Tree;
use Mojo::Base -base;
use Mojo::Util qw(dumper);
use Mojo::Collection 'c';
use DBI;
use Carp qw(croak);
  
our $VERSION  = '0.01';

sub new {
	my $class = shift;
	my %args = @_;

	my $config = {};
	if(exists $args{'mysql'} && $args{'mysql'} && ref $args{'mysql'} eq 'MojoX::Mysql'){
		$config->{'mysql'} = $args{'mysql'};
	}
	else{
		croak qq/invalid MojoX::Mysql object/;
	}

	if(exists $args{'table'} && $args{'table'} && $args{'table'} =~ m/^[0-9a-z_-]+$/){
		$config->{'table'} = $args{'table'};
	}
	else{
		croak qq/invalid table/;
	}

	if(exists $args{'column'} && $args{'column'} && ref $args{'column'} eq 'HASH'){
		$config->{'column'} = $args{'column'};
	}
	else{
		croak qq/invalid column/;
	}

	if(exists $args{'length'} && $args{'length'} && $args{'length'} =~ m/^[0-9]+$/){
		$config->{'length'} = $args{'length'};
	}
	else{
		croak qq/invalid column/;
	}


	return $class->SUPER::new($config);
}

sub mysql {
	return shift->{'mysql'};
}

sub add {
	my ($self,$name,$parent_id) = @_;

	my $table = $self->{'table'};
	my $column_id        = $self->{'column'}->{'id'};
	my $column_name      = $self->{'column'}->{'name'};
	my $column_path      = $self->{'column'}->{'path'};
	my $column_level     = $self->{'column'}->{'level'};
	my $column_parent_id = $self->{'column'}->{'parent_id'};

	my $parent_path = undef;
	if(defined $parent_id && $parent_id){
		my $get_id = $self->get_id($parent_id);
		$parent_path = $get_id->{'path'};
	}

	croak "invalid name" if(!$name);

	# Создаем запись
	my ($insertid,$counter) = $self->mysql->do("INSERT INTO `$table` (`$column_name`) VALUES (?)", $name);

	# Формируем материлизованный путь
	my $path = $self->make_path($insertid);

	$path = $parent_path.$path if(defined $parent_path);
	my $level = $self->make_level($path); # Узнает текущий уровень

	my (undef,$update_counter) = $self->mysql->do(
		"UPDATE `$table` SET `$column_path` = ?, `$column_level` = ?, `$column_parent_id` = ? WHERE `$column_id` = ?;",
		$path,$level,$parent_id,$insertid
	);

	croak "invalid update table" if($update_counter != 1);
	return $insertid;
}

# Удаляет текущего элемент и детей
sub delete {
	my ($self,$id) = @_;

	my $path = undef;
	my $get_id = $self->get_id($id);
	if(defined $get_id){
		$path = $get_id->{'path'};
	}
	else{
		croak "invalid id:$id";
	}

	my $table       = $self->{'table'};
	my $column_path = $self->{'column'}->{'path'};
	my ($insertid,$counter) = $self->mysql->do("DELETE FROM `$table` WHERE `$column_path` LIKE '$path%';");
	if($counter > 0){
		return $counter;
	}
	else{
		croak "Unable to delete";
	}
}

sub move {
	my ($self,$id,$target_id) = @_;
	my $table = $self->{'table'};
	my $column_id        = $self->{'column'}->{'id'};
	my $column_name      = $self->{'column'}->{'name'};
	my $column_path      = $self->{'column'}->{'path'};
	my $column_level     = $self->{'column'}->{'level'};
	my $column_parent_id = $self->{'column'}->{'parent_id'};

	my $get_id = $self->get_id($id);
	croak "invalid id:$id" if(!defined $id);

	my $get_target_id = $self->get_id($target_id);
	croak "invalid id:$get_target_id" if(!defined $get_target_id);

	croak "Impossible to transfer to itself or children" if($id eq $target_id);

	my $path        = $get_id->{'path'};
	my $path_target = $get_target_id->{'path'};
	croak "Impossible to transfer to itself or children" if($path =~ m/^$path_target/);

	my $length = $self->{'length'};
	my $collection = $self->mysql->query("SELECT `$column_id` as `id`, `$column_path` as `path` FROM `$table` WHERE `$column_path` LIKE '$path%';");
	$collection->each(sub {
		my $e = shift;
		my $id = $e->{'id'};
		if($e->{'path'} =~ m/(?<path>($path\d*))/g){
			my $path = $path_target.$+{'path'};
			my $level = $self->make_level($path);

			my $parent_id = 'NULL';
			$parent_id = int $+{'parent_id'} if($path =~ m/(?<parent_id>(\d{$length}))\d{$length}$/);
			$self->mysql->do("UPDATE `$table` SET `$column_path` = ?, `level` = ?, `$column_parent_id` = ? WHERE `$column_id` = ?",$path,$level,$parent_id,$id);
		}
	});
}

# Получение очереди по id
sub get_id {
	my ($self,$id) = @_;

	my $table = $self->{'table'};
	my $column_id        = $self->{'column'}->{'id'};
	my $column_name      = $self->{'column'}->{'name'};
	my $column_path      = $self->{'column'}->{'path'};
	my $column_level     = $self->{'column'}->{'level'};
	my $column_parent_id = $self->{'column'}->{'parent_id'};

	my ($collection,$counter) = $self->mysql->query("SELECT `$column_id`, `$column_path`, `$column_name`, `$column_level`, `$column_parent_id` FROM `$table` WHERE `$column_id` = ? LIMIT 1", $id);
	croak "invalid id:$id" if($counter eq '0E0');

	my $result = $collection->last;

	# Получаем всех детей
	my $path = $result->{'path'};
	my $level = $result->{'level'};
	$result->{'children'} = $self->mysql->query("
		SELECT `$column_id`, `$column_path`, `$column_name`, `$column_level`, `$column_parent_id` FROM `$table`
		WHERE `$column_path` LIKE '$path%' AND `level` != ?
	",$level);

	# Получаем всех родителей
	my @parent = ();
	my $length = $self->{'length'};
	for(($path =~ m/(\d{$length})/g)){
		push(@parent, int $_);
	}
	@parent = grep(!/$id/, @parent);
	my $parent = join(",",@parent);

	if(defined $parent && $parent){
		$parent = $self->mysql->query("SELECT `$column_id`, `$column_path`, `$column_name`, `$column_level`, `$column_parent_id` FROM `$table` WHERE `$column_id` IN($parent)");
	}
	else {
		$parent = c();
	}

	$result->{'parent'} = $parent;
	return $result;
}

sub make_path {
	my ($self,$id) = @_;
	my $length = $self->{'length'};
	my $length_id = length $id;
	if($length_id < $length){
		my $zero = '0' x ($length - $length_id);
		$id = $zero.$id;
	}
	return $id;
}

sub make_level {
	my ($self,$path) = @_;
	my $length = $self->{'length'};
	my @counter = ($path =~ m/([0-9]{$length})/g);
	return scalar @counter;
}


1;
