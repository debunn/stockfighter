h1 = {}
h2 = {1 => {'timestring' => {qty: 1, price: 1000}}}
h3 = {1 => {'timestring2' => {qty: 1, price: 1000}}}
if h1.has_key?(1)
  h1[1]['timestring'] = {'qty' => 1, 'price' => 1000}
else
  h1[1] = {'timestring' => {'qty' => 1, 'price' => 1000}}
end
if h1.has_key?(1)
  h1[1]['timestring2'] = {'qty' => 1, 'price' => 1000}
else
  h1[1] = {'timestring2' => {'qty' => 1, 'price' => 1000}}
end
p h1
