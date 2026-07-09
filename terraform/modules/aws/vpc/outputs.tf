output "vpc_id"             { value = aws_vpc.main.id }
output "vpc_cidr"           { value = aws_vpc.main.cidr_block }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "database_subnet_ids"{ value = aws_subnet.database[*].id }
output "db_subnet_group_name"{ value = aws_db_subnet_group.main.name }
output "nat_gateway_ids"    { value = aws_nat_gateway.main[*].id }
