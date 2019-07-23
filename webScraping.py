from lxml import html
import requests

url = "https://en.wikipedia.org/wiki/Outline_of_the_Marvel_Cinematic_Universe"
resp = requests.get(url)
tree = html.fromstring(resp.content)
elements = tree.xpath('//*[@id="mw-content-text"]/div/table[2]/tbody/tr[*]/th/i/a')
base_url = "https://en.wikipedia.org"
links = [base_url + element.attrib['href'] for element in elements]
print(links)
