variable "security_group_name" {}
variable "resource_name" {}
variable "region" {}
variable "ports" {
    type = list
}
variable "ingress_cidrs" {
    type = list(string)
}
variable "egress_cidrs" {
    type = list(string)
}
variable "name_id" {
    type = string
}
variable "tags" {}
