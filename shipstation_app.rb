class ShipStationApp < EndpointBase::Sinatra::Base
  set :public_folder, 'public'
  set :logging, true

  Honeybadger.configure do |config|
    config.api_key = ENV['HONEYBADGER_KEY']
    config.environment_name = ENV['RACK_ENV']
  end

  post '/add_order' do

    begin
      authenticate_shipstation

      @order = @payload[:order]

      # create the order
      resource = new_order(@order)
      @client.AddToOrders(resource)
      shipstation_response = @client.save_changes

      # create the line items
      @shipstation_id = shipstation_response.first.OrderID

      new_order_items(@order[:line_items], @shipstation_id).each do |resource|
        @client.AddToOrderItems(resource)
      end
      @client.save_changes

    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful create attempt
      result 500, "Unable to create ShipStation order. Error: #{e.message}"
    end

    # return a partial order object with the shipstation id
    add_object :order, {id: @order[:id], shipstation_id: @shipstation_id}
    result 200, "Order created in ShipStation: #{@shipstation_id}"
  end

  # Use this to lookup the real id of the order based on the shipstation shipment id and map
  # the shipment tracking information to it
  post '/map_tracking' do
    begin
      authenticate_shipstation

      @shipment = @payload[:shipment]
      store_id = @config[:shipstation_store_id]

      @client.Orders.filter("OrderID eq #{@shipment[:order_id]}")

      resource = @client.execute.first
      @order_number = resource.OrderNumber

      # in some cases we might not be interested in orders from other stores (manual orders, etc.)
      if store_id.blank? || (store_id.to_i == resource.StoreID)
        # now we can get the real order number and update with the tracking information
        add_object :order, {
          id: @order_number,
          tracking_number: @shipment[:tracking],
          shipping_status: "shipped"
        }
      else
        result 200, "Order does not match the specified store id: #{store_id}"
      end

    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful get attempt
      result 500, "Unable to get order from ShipStation. Error: #{e.message}"
    end

    result 200, "Order #{@order_number} has shipped with tracking: #{@shipment[:tracking]}"
  end

  post '/get_shipments' do

    begin
      authenticate_shipstation

      since = Time.parse(@config[:since]).iso8601

      @client.Shipments.filter("CreateDate ge datetime'#{since}'")
      shipstation_result = @client.execute

      # TODO - get shipping carrier, etc.
      shipstation_result.each do |resource|
        add_object :shipment, {
          id: resource.ShipmentID.to_s,
          tracking: resource.TrackingNumber,
          order_id: resource.OrderID.to_s,
          shipping_status: "shipped"
        }
      end
      @kount = shipstation_result.count

      # ShipStation appears to be recording their timestamps in local (PST) time but storing that timestamp
      # as UTC (so it's basically 7-8 hours off the correct time (depending on daylight savings). To compensate
      # for this the timestamp we use for "now" should be adjusted accordingly.
      now = (Time.now + Time.zone_offset("PDT")).utc.iso8601

      # Tell Wombat to use the current time as the 'high watermark' the next time it checks
      add_parameter 'since', now
    rescue => e
      # tell Honeybadger
      log_exception(e)

      # tell the hub about the unsuccessful get attempt
      result 500, "Unable to get shipments from ShipStation. Error: #{e.message}"
    end

    result 200, "Retrieved #{@kount} shipments from ShipStation"
  end

  private

  def authenticate_shipstation
    auth = {:username => @config[:username], :password => @config[:password]}
    @client = OData::Service.new("https://data.shipstation.com/1.1", auth)
  end

  def get_service_id(method_name)
    service_id = case method_name
      when 'UPS Ground' then 26 #UPS Ground
      when 'UPS Express' then 31 #UPS Next Day Air Saver
      when 'DHL International' then 148 #Express Worldwide
      # USPS
      when 'USPS First Class Mail' then 10
      when 'USPS Priority Mail (Endicia)' then 21 #USPS Priority Mail (Provider = Endicia)
      when 'International Priority Airmail (Endicia)' then 89 #USPS (Provider = Endicia)
      # FedEx
      when 'FedEx SmartPost Parcel Select' then 66
      when 'FedEx SmartPost Parcel Select Lightweight' then 169
    end
  end

  def get_carrier_id(carrier_name)
    carrier_id = case carrier_name
      when "UPS" then 3
      when "DHL" then 13
      when 'USPS' then 1
      when 'FedEx' then 4
      else 0
    end
  end

  def new_order(order)
    raise ":shipping_address required" unless order[:shipping_address]
    resource = Order.new
    resource.BuyerEmail = order[:email]
    resource.MarketplaceID = @config[:marketplace_id]
    resource.NotesFromBuyer = order[:delivery_instructions]
    resource.OrderDate = order[:placed_on]
    resource.PayDate = order[:placed_on]
    resource.PackageTypeID = 3 # This is equivalent to 'Package'
    resource.OrderNumber = order[:id]
    resource.OrderStatusID = 2
    resource.StoreID = @config[:shipstation_store_id] unless @config[:shipstation_store_id].blank?
    resource.OrderTotal = order[:totals][:order].to_s
    #resource.RequestedShippingService = "USPS Priority Mail"
    resource.ShipCity = order[:shipping_address][:city]
    #resource.ShipCompany = "FOO" # company name on shipping address
    resource.ShipCountryCode = order[:shipping_address][:country]
    resource.ProviderID = get_carrier_id(order[:shipping_carrier])
    resource.ServiceID = get_service_id(order[:shipping_method])
    resource.ShipName = order[:shipping_address][:firstname] + " " + order[:shipping_address][:lastname]
    resource.ShipPhone = order[:shipping_address][:phone]
    resource.ShipPostalCode = order[:shipping_address][:zipcode]
    resource.ShipState = order[:shipping_address][:state]
    resource.ShipStreet1 = order[:shipping_address][:address1]
    resource.ShipStreet2 = order[:shipping_address][:address2]
    resource.CustomField1 = order[:custom_field1]
    resource.CustomField2 = order[:custom_field2]
    resource.CustomField3 = order[:custom_field3]
    resource
  end

  def new_order_items(line_items, shipstation_id)
    item_resources = []

    line_items.each do |item|
      resource = OrderItem.new
      resource.OrderID = shipstation_id
      resource.Quantity = item[:quantity]
      resource.SKU = item[:product_id]
      resource.Description = item[:name]
      resource.UnitPrice = item[:price].to_s
      resource.ThumbnailUrl = item[:image_url]

      if item[:properties]
        properties = ""
        item[:properties].each do |key, value|
          properties += "#{key}:#{value}\n"
        end
        resource.Options = properties
      end

      item_resources << resource
    end
    item_resources
  end
end
