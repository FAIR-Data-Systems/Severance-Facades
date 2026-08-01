# frozen_string_literal: true

require 'time'

# Maps a Beacon-shaped `query.filters` array onto the CARE-SM-2 / Severance
# binding contract (see ../../severance-queries/README.md).
#
# Built primarily against ERDERA's actual RDVP-Portal-backend client (see
# BeaconFilterType.java / BeaconFilterHandler.java in that repo), which is
# the only real caller this facade has today, and which deviates from the
# GA4GH Beacon v2 spec in several ways -- most importantly by never sending
# `requestedGranularity` and by always sending age-like filters as a
# min/max range rather than an exact match. Generic Beacon v2 alphanumeric
# filters (`{id, operator: "=", value}`) work too, since that shape is a
# subset of what's handled here.
module FilterMapper
  OBO = 'http://purl.obolibrary.org/obo/'

  # Real filter ids the VP sends -- see BeaconFilterType.java.
  SEX_FILTER_ID = 'obo:NCIT_C28421'
  AGE_THIS_YEAR_FILTER_ID = 'obo:NCIT_C83164' # VP's "age this year" -- reuses Birthyear's NCIT code, see note below
  SYMPTOM_ONSET_FILTER_ID = 'obo:NCIT_C124353'
  AGE_AT_DIAGNOSIS_FILTER_ID = 'obo:NCIT_C156420'

  # Ids BeaconFilterType.java defines but the VP frontend/backend never
  # actually populates today (no `symptoms` / `geneVariant` field exists on
  # SearchRequest.java). Supported here anyway for a future spec-compliant
  # caller -- see ../../severance-queries/README.md.
  SYMPTOM_FILTER_ID = 'sio:SIO_010056'
  GENE_VARIANT_FILTER_ID = 'edam:data_2295'

  RANGE_FAMILIES = {
    AGE_THIS_YEAR_FILTER_ID => :age_this_year,
    SYMPTOM_ONSET_FILTER_ID => :age_symptom_onset,
    AGE_AT_DIAGNOSIS_FILTER_ID => :age_diagnosis
  }.freeze

  Result = Struct.new(:bindings, :unsupported_filters)

  # @param beacon_filters [Array<Hash>] the `query.filters` array
  # @param reference_year [Integer] "today" for the ageThisYear -> birth
  #   year inversion; overridable for tests
  # @return [Result] bindings hash for Severance, plus any unsupported-filter notes
  def self.to_bindings(beacon_filters, reference_year: Time.now.year)
    bindings = {}
    unsupported = []

    Array(beacon_filters).each do |filter|
      id = filter['id'] || filter[:id]
      next if id.nil?

      if id.is_a?(Array)
        # Ontology filter shape: { "id": ["ordo:Orphanet_730", ...] }, no
        # operator/value -- this is how the VP sends disease codes.
        apply_disease(bindings, unsupported, id)
        next
      end

      operator = filter['operator'] || filter[:operator]
      value = filter['value'] || filter[:value]
      next if value.nil?

      dispatch(bindings, unsupported, id.to_s, operator, value, reference_year)
    end

    Result.new(bindings, unsupported)
  end

  def self.dispatch(bindings, unsupported, id, operator, value, reference_year)
    if id == SEX_FILTER_ID
      apply_sex(bindings, unsupported, value)
    elsif RANGE_FAMILIES.key?(id)
      apply_range(bindings, RANGE_FAMILIES[id], operator, value, reference_year)
    elsif id == SYMPTOM_FILTER_ID
      bindings['symptom'] = full_iri(value)
    elsif id == GENE_VARIANT_FILTER_ID
      bindings['gene_variant'] = value.to_s
    else
      unsupported << id
    end
  end

  def self.apply_disease(bindings, unsupported, ids)
    return if ids.empty?

    if ids.size > 1
      unsupported << 'disease (multiple ontology terms requested; ' \
                     'Severance bindings are scalar -- only the first was used)'
    end
    bindings['disease'] = full_iri_for_curie(ids.first)
  end

  def self.apply_sex(bindings, unsupported, value)
    values = Array(value)
    if values.size > 1
      unsupported << 'sex (multiple values requested; Severance bindings are scalar -- only the first was used)'
    end
    bindings['sex'] = full_iri(values.first)
  end

  # The VP's "ageThisYear" filter is tagged with Birthyear's NCIT code
  # (obo:NCIT_C83164) but its value is an actual age in years (their own
  # default query uses a 0-100 range, which would be nonsensical as birth
  # years) -- see severance-queries/README.md. Convert the age range into
  # the equivalent birth-year range: an age minimum corresponds to the
  # LATEST birth year that satisfies it, and vice versa.
  def self.apply_range(bindings, family, operator, value, reference_year)
    n = value.to_i

    if family == :age_this_year
      case operator.to_s
      when '>=' then bindings['birthyear_max'] = reference_year - n
      when '<=' then bindings['birthyear_min'] = reference_year - n
      when '=' then bindings['birthyear_min'] = bindings['birthyear_max'] = reference_year - n
      end
    else
      case operator.to_s
      when '>=' then bindings["#{family}_min"] = n
      when '<=' then bindings["#{family}_max"] = n
      when '=' then bindings["#{family}_min"] = bindings["#{family}_max"] = n
      end
    end
  end

  def self.full_iri(value)
    v = value.to_s
    return v if v.start_with?('http://', 'https://')

    "#{OBO}#{v.sub(/\Aobo:/, '')}"
  end

  def self.full_iri_for_curie(curie)
    v = curie.to_s
    return v if v.start_with?('http://', 'https://')

    prefix, local = v.split(':', 2)
    case prefix
    when 'ordo' then "http://www.orpha.net/ORDO/#{local}"
    when 'obo' then "#{OBO}#{local}"
    when 'hp' then "#{OBO}HP_#{local}"
    else v
    end
  end
end
