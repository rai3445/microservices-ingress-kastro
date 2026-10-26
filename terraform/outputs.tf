output "load_balancer_dns" {
  description = "Public Application Load Balancer DNS"
  value       = aws_lb.app_alb.dns_name
}

output "home_url" {
  description = "Home Page URL"
  value       = "http://${aws_lb.app_alb.dns_name}/"
}

output "about_url" {
  description = "About Page URL"
  value       = "http://${aws_lb.app_alb.dns_name}/about"
}

output "services_url" {
  description = "Services Page URL"
  value       = "http://${aws_lb.app_alb.dns_name}/services"
}

output "contact_url" {
  description = "Contact Page URL"
  value       = "http://${aws_lb.app_alb.dns_name}/contact"
}
